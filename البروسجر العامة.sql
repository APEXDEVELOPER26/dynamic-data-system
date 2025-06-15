-------------------------------------------
-- 1. إنشاء جداول الدعم
-------------------------------------------

-- جدول تتبع العمليات
CREATE TABLE audit_trail (
    audit_id        RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    table_name      VARCHAR2(100) NOT NULL,
    operation_type  VARCHAR2(1) NOT NULL,   -- I/U/D
    sql_statement   CLOB NOT NULL,
    user_name       VARCHAR2(100) NOT NULL,
    operation_date  TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE audit_trail IS 'جدول لتسجيل جميع عمليات إضافة/تعديل/حذف البيانات';
COMMENT ON COLUMN audit_trail.operation_type IS 'نوع العملية: I-إضافة, U-تحديث, D-حذف';

-- جدول الإشعارات
CREATE TABLE notifications (
    notification_id RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    table_name      VARCHAR2(100) NOT NULL,
    record_id       VARCHAR2(100),
    message         VARCHAR2(1000) NOT NULL,
    created_by      VARCHAR2(100) NOT NULL,
    created_on      TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE notifications IS 'جدول إشعارات سير العمل';
COMMENT ON COLUMN notifications.message IS 'نص الإشعار';

-------------------------------------------
-- 2. إنشاء حزمة MW
-------------------------------------------

CREATE OR REPLACE PACKAGE MW AS
    -- الدالة الرئيسية للمعالجة
    FUNCTION MAIN(
        p_row_status    VARCHAR2,   -- حالة الصف (I,U,D)
        p_object_type   VARCHAR2,   -- نوع الكائن (table)
        p_object_name   VARCHAR2,   -- اسم الجدول
        p_items_list    VARCHAR2,   -- قائمة العناصر
        p_condition     VARCHAR2    -- الشرط
    ) RETURN CLOB;
    
    -- دالة مساعدة للإخفاء (إن لزم)
    FUNCTION MASK(p_table_name VARCHAR2, p_mask_type VARCHAR2) RETURN VARCHAR2;
    
    -- متغيرات عامة
    G_global_id RAW(16);
END MW;
/

CREATE OR REPLACE PACKAGE BODY MW AS

    -- دالة MASK البسيطة (يمكن تطويرها لاحقاً)
    FUNCTION MASK(p_table_name VARCHAR2, p_mask_type VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        -- يمكنك إضافة منطق التشفير هنا إذا لزم
        RETURN p_table_name;
    END MASK;

    -- الدالة الرئيسية للمعالجة
    FUNCTION MAIN(
        p_row_status    VARCHAR2,
        p_object_type   VARCHAR2,
        p_object_name   VARCHAR2,
        p_items_list    VARCHAR2,
        p_condition     VARCHAR2
    ) RETURN CLOB IS
        v_sql          VARCHAR2(4000);
        v_columns      VARCHAR2(4000);
        v_values       VARCHAR2(4000);
        v_set_clause   VARCHAR2(4000);
        v_guid         RAW(16);
        v_res          CLOB;
        v_item_name    VARCHAR2(100);
        v_item_value   VARCHAR2(4000);
        v_page_prefix  VARCHAR2(10) := 'P' || V('APP_PAGE_ID') || '_';
        v_has_workflow BOOLEAN := FALSE;
    BEGIN
        -- معالجة قائمة العناصر
        FOR item IN (
            SELECT TRIM(regexp_substr(p_items_list, '[^,]+', 1, LEVEL)) item_name
            FROM dual 
            CONNECT BY LEVEL <= regexp_count(p_items_list, ',') + 1
        )
        LOOP
            v_item_name := item.item_name;
            v_item_value := NULL;
            
            -- 1. معالجة متغيرات الجلسة [:G_VAR]
            IF v_item_name LIKE '%[:%]%' THEN
                DECLARE
                    v_session_var VARCHAR2(100);
                BEGIN
                    v_session_var := TRIM(SUBSTR(v_item_name, 
                                         INSTR(v_item_name, '[') + 1, 
                                         INSTR(v_item_name, ']') - INSTR(v_item_name, '[') - 1));
                    
                    -- التحقق من وجود المتغير قبل استخدامه
                    IF v_session_var IS NOT NULL AND v_session_var LIKE ':%' THEN
                        v_session_var := REPLACE(v_session_var, ':', '');
                        v_item_value := APEX_UTIL.GET_SESSION_STATE(v_session_var);
                    END IF;
                    
                    v_item_name := SUBSTR(v_item_name, 1, INSTR(v_item_name, '[') - 1);
                END;
                
            -- 2. معالجة توابع النظام [SYSTIMESTAMP]
            ELSIF v_item_name LIKE '%[SYSTIMESTAMP]' THEN
                v_item_value := TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF');
                v_item_name := REPLACE(v_item_name, '[SYSTIMESTAMP]', '');
                
            ELSIF v_item_name LIKE '%[SYSDATE]' THEN
                v_item_value := TO_CHAR(SYSDATE, 'YYYY-MM-DD');
                v_item_name := REPLACE(v_item_name, '[SYSDATE]', '');
                
            -- 3. معالجة التعبيرات المركبة ['||VR_VAR||']
            ELSIF v_item_name LIKE '%[''%||%||%'']%' THEN
                DECLARE
                    v_expr VARCHAR2(4000);
                BEGIN
                    v_expr := REPLACE(SUBSTR(v_item_name, INSTR(v_item_name, '[') + 1), ']');
                    
                    -- استبدال المتغيرات بقيمها
                    v_expr := REPLACE(v_expr, ':APP_USER', '''' || V('APP_USER') || '''');
                    v_expr := REPLACE(v_expr, ':G_ORG_ID', '''' || V('G_ORG_ID') || '''');
                    
                    -- تنفيذ التعبير
                    EXECUTE IMMEDIATE 'BEGIN :1 := ' || v_expr || '; END;' USING OUT v_item_value;
                    
                    v_item_name := SUBSTR(v_item_name, 1, INSTR(v_item_name, '[') - 1);
                EXCEPTION
                    WHEN OTHERS THEN
                        v_item_value := NULL;
                END;
                
            -- 4. معالجة العناصر العادية
            ELSE
                v_item_value := APEX_UTIL.GET_SESSION_STATE(v_item_name);
            END IF;
            
            -- التحقق من وجود متغير سير العمل
            IF UPPER(v_item_name) = 'HAS_WORKFLOW' THEN
                v_has_workflow := (UPPER(v_item_value) = 'Y');
                CONTINUE;
            END IF;
            
            -- إزالة بادئة الصفحة إذا وجدت
            v_item_name := REPLACE(v_item_name, v_page_prefix, '');
            
            -- تجاهل العناصر الفارغة
            IF v_item_name IS NULL THEN CONTINUE; END IF;
            
            -- بناء أجزاء SQL
            CASE p_row_status
                WHEN 'I' THEN
                    v_columns := v_columns || v_item_name || ',';
                    v_values := v_values || '''' || v_item_value || ''',';
                WHEN 'U' THEN
                    v_set_clause := v_set_clause || v_item_name || ' = ''' || v_item_value || ''',';
            END CASE;
        END LOOP;
        
        -- إزالة الفواصل الزائدة
        IF v_columns IS NOT NULL THEN
            v_columns := RTRIM(v_columns, ',');
        END IF;
        
        IF v_values IS NOT NULL THEN
            v_values := RTRIM(v_values, ',');
        END IF;
        
        IF v_set_clause IS NOT NULL THEN
            v_set_clause := RTRIM(v_set_clause, ',');
        END IF;
        
        -- بناء وتنفيذ SQL
        CASE p_row_status
            WHEN 'I' THEN
                -- إضافة سجل جديد
                v_sql := 'INSERT INTO ' || p_object_name || '(' || v_columns || ') VALUES (' || v_values || ')';
                EXECUTE IMMEDIATE v_sql;
                
                -- استرجاع الـ GUID للسجل الجديد
                BEGIN
                    EXECUTE IMMEDIATE 
                        'SELECT GUID FROM ' || p_object_name || 
                        ' WHERE ROWID = (SELECT MAX(ROWID) FROM ' || p_object_name || ')' 
                        INTO v_guid;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_guid := NULL;
                END;
                
                -- تخزين الـ GUID في المتغير العام
                G_global_id := v_guid;
                v_res := '{"data":"' || v_guid || '"}';
                
            WHEN 'U' THEN
                -- تحديث سجل موجود
                v_sql := 'UPDATE ' || p_object_name || ' SET ' || v_set_clause || ' WHERE ' || p_condition;
                EXECUTE IMMEDIATE v_sql;
                v_res := '{"data":"1"}';
                
            WHEN 'D' THEN
                -- حذف سجل
                v_sql := 'DELETE FROM ' || p_object_name || ' WHERE ' || p_condition;
                EXECUTE IMMEDIATE v_sql;
                v_res := '{"data":"1"}';
        END CASE;
        
        -- تسجيل التتبع
        INSERT INTO audit_trail (
            table_name, operation_type, 
            sql_statement, user_name
        ) VALUES (
            p_object_name, p_row_status, 
            v_sql, V('APP_USER')
        );
        
        -- توليد إشعارات سير العمل إذا مطلوب
        IF v_has_workflow THEN
            INSERT INTO notifications (
                table_name, record_id,
                message, created_by
            ) VALUES (
                p_object_name, v_guid,
                'تم تنفيذ العملية: ' || p_row_status,
                V('APP_USER')
            );
        END IF;
        
        -- إرجاع النتيجة
        RETURN '{"code":1,"msg":"تمت العملية بنجاح",' || v_res || '}';
        
    EXCEPTION
        WHEN OTHERS THEN
            -- إرجاع رسالة الخطأ
            RETURN '{"code":0,"msg":"' || REPLACE(DBMS_UTILITY.FORMAT_ERROR_STACK, '"', '') || '"}';
    END MAIN;
    
END MW;
/

-------------------------------------------
-- 3. مثال استخدام في كتلة مجهولة (للاختبار)
-------------------------------------------

DECLARE
    -- إنشاء جدول تجريبي
    PROCEDURE create_test_table IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE test_table (
            guid RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
            name VARCHAR2(100),
            salary NUMBER,
            department VARCHAR2(100),
            created_by VARCHAR2(100),
            created_date TIMESTAMP,
            has_workflow VARCHAR2(1) DEFAULT ''N''
        )';
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
    
    -- تنظيف الجدول التجريبي
    PROCEDURE cleanup_test IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLE test_table PURGE';
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;
    
    vr_res CLOB;
    v_guid VARCHAR2(32);
BEGIN
    -- إعداد بيئة الاختبار
    cleanup_test;
    create_test_table;
    
    -- تعيين قيم جلسة افتراضية
    APEX_UTIL.SET_SESSION_STATE('P100_NAME', 'أحمد محمد');
    APEX_UTIL.SET_SESSION_STATE('P100_SALARY', '5000');
    APEX_UTIL.SET_SESSION_STATE('P100_DEPARTMENT', 'المبيعات');
    APEX_UTIL.SET_SESSION_STATE('APP_USER', 'TEST_USER');
    APEX_UTIL.SET_SESSION_STATE('G_ORG_ID', 'ORG_001');
    
    -- اختبار إضافة سجل جديد مع سير العمل
    vr_res := MW.MAIN(
        p_row_status  => 'I',
        p_object_type => 'table',
        p_object_name => 'TEST_TABLE',
        p_items_list  => 'P100_NAME,P100_SALARY,P100_DEPARTMENT,'
                      || 'CREATED_BY[:APP_USER],CREATED_DATE[SYSTIMESTAMP],'
                      || 'HAS_WORKFLOW[Y],'
                      || 'BONUS[''||:P100_SALARY * 0.1||'']',
        p_condition   => NULL
    );
    
    DBMS_OUTPUT.PUT_LINE('نتيجة الإضافة: ' || vr_res);
    
    -- استخراج الـ GUID من النتيجة
    v_guid := JSON_VALUE(vr_res, '$.data');
    DBMS_OUTPUT.PUT_LINE('GUID المولّد: ' || v_guid);
    
    -- التحقق من إشعار سير العمل
    DECLARE
        v_notif_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_notif_count 
        FROM notifications 
        WHERE record_id = v_guid;
        
        DBMS_OUTPUT.PUT_LINE('عدد إشعارات سير العمل: ' || v_notif_count);
    END;
    
    -- اختبار تحديث السجل
    APEX_UTIL.SET_SESSION_STATE('P100_SALARY', '6000');
    
    vr_res := MW.MAIN(
        p_row_status  => 'U',
        p_object_type => 'table',
        p_object_name => 'TEST_TABLE',
        p_items_list  => 'P100_SALARY',
        p_condition   => 'GUID = ''' || v_guid || ''''
    );
    
    DBMS_OUTPUT.PUT_LINE('نتيجة التحديث: ' || vr_res);
    
    -- اختبار الحذف
    vr_res := MW.MAIN(
        p_row_status  => 'D',
        p_object_type => 'table',
        p_object_name => 'TEST_TABLE',
        p_items_list  => NULL,
        p_condition   => 'GUID = ''' || v_guid || ''''
    );
    
    DBMS_OUTPUT.PUT_LINE('نتيجة الحذف: ' || vr_res);
    
    -- التنظيف بعد الاختبار
    cleanup_test;
END;
/

-------------------------------------------
-- 4. مثال استخدام في شاشة APEX (كما طلبت)
-------------------------------------------

/*
DECLARE
    vr_res       CLOB; 
    vr_condition VARCHAR2(500); 
BEGIN
    -- بناء الشرط باستخدام GUID
    vr_condition := 'GUID = ''' || :P188_GUID || '''';
    
    -- استدعاء الدالة الرئيسية بشكل مباشر
    vr_res := MW.MAIN(
        p_row_status  => :APEX$ROW_STATUS,
        p_object_type => 'table',
        p_object_name => MW.MASK('CUR_OPENNING','PI'),
        p_items_list  => 'P188_GUID,ORG_ID[:G_ORG_ID],P188_PAPER_NO,P188_SEARIAL_NO,' ||
                         'P188_SEQUENCE_NO,P188_ACTION_DATE,P188_PROJECT_ID,' ||
                         'P188_BRANCH_ID,P188_DESCRIPTION,P188_TRANSECTION_ID,' ||
                         'U_USER[:APP_USER],U_DATE[SYSTIMESTAMP],LVL[:G_LVL],' ||
                         'PROCESS_CAT[:P0_CAT],PROCESS_STAGE[:P0_STAGE],' ||
                         'BONUS[''||:P188_BASE_SALARY * 0.1||''],' ||
                         'HAS_WORKFLOW[:P188_HAS_WORKFLOW]',
        p_condition   => vr_condition
    );
    
    -- معالجة النتيجة للسجلات الجديدة
    IF :APEX$ROW_STATUS = 'I' AND JSON_VALUE(vr_res, '$.data') IS NOT NULL THEN
        -- الطريقة المثلى: استخدام المتغير العام
        :P188_ACTION_ID := MW.G_global_id;
        
        -- بديل: الاستعلام من الجدول (إذا لزم)
        /*
        EXECUTE IMMEDIATE 
            'SELECT ACTION_ID FROM ' || MW.MASK('CUR_OPENNING','PI') ||
            ' WHERE guid = :guid'
            INTO :P188_ACTION_ID
            USING JSON_VALUE(vr_res, '$.data');
        */
    END IF;
    
    -- معالجة رسائل النظام
    IF JSON_VALUE(vr_res, '$.code') = '1' THEN
        -- نجاح العملية
        APEX_UTIL.SET_SESSION_STATE(
            'G_SUCCESS_MESSAGE', 
            'تم ' || CASE :APEX$ROW_STATUS 
                     WHEN 'I' THEN 'إنشاء' 
                     WHEN 'U' THEN 'تحديث' 
                     WHEN 'D' THEN 'حذف' 
                     END || ' السجل بنجاح'
        );
    ELSE
        -- خطأ في العملية
        APEX_UTIL.SET_SESSION_STATE(
            'G_ERROR_MESSAGE', 
            JSON_VALUE(vr_res, '$.msg')
        );
    END IF;
END;
*/
---------------------الاستدعاء
DECLARE
    vr_res CLOB;
BEGIN
    vr_res := MW.MAIN(
        :APEX$ROW_STATUS,
        'table',
        MW.MASK('YOUR_TABLE','PI'),
        'ITEM1,ITEM2[:G_VAR],ITEM3[SYSTIMESTAMP],ITEM4[''||EXPR||''],HAS_WORKFLOW[:P_HAS_WF]',
        'ID = ' || :P_ID
    );
    
    IF :APEX$ROW_STATUS = 'I' THEN
        :P_NEW_ID := MW.G_global_id;
    END IF;
END;