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
            
            -- استخراج القيمة من التعبيرات الخاصة
            IF v_item_name LIKE '%[:%]%' THEN
                -- متغير جلسة [:G_VAR]
                v_item_value := APEX_UTIL.GET_SESSION_STATE(
                    TRIM(SUBSTR(v_item_name, INSTR(v_item_name, '[') + 1, 
                         INSTR(v_item_name, ']') - INSTR(v_item_name, '[') - 1))
                );
                v_item_name := SUBSTR(v_item_name, 1, INSTR(v_item_name, '[') - 1);
                
            ELSIF v_item_name LIKE '%[SYSTIMESTAMP]' THEN
                -- قيمة تاريخ ووقت النظام
                v_item_value := TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF');
                v_item_name := REPLACE(v_item_name, '[SYSTIMESTAMP]', '');
                
            ELSIF v_item_name LIKE '%[SYSDATE]' THEN
                -- قيمة تاريخ النظام
                v_item_value := TO_CHAR(SYSDATE, 'YYYY-MM-DD');
                v_item_name := REPLACE(v_item_name, '[SYSDATE]', '');
                
            ELSIF v_item_name LIKE '%[''%'']%' THEN
                -- تعبير مركب
                v_item_value := REPLACE(SUBSTR(v_item_name, INSTR(v_item_name, '[') + 1), ']');
                BEGIN
                    EXECUTE IMMEDIATE 'BEGIN :1 := ' || v_item_value || '; END;' USING OUT v_item_value;
                EXCEPTION
                    WHEN OTHERS THEN
                        v_item_value := NULL;
                END;
                v_item_name := SUBSTR(v_item_name, 1, INSTR(v_item_name, '[') - 1);
                
            ELSE
                -- عنصر عادي
                v_item_value := APEX_UTIL.GET_SESSION_STATE(v_item_name);
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
        
        -- إرجاع النتيجة
        RETURN '{"code":1,"msg":"تمت العملية بنجاح",' || v_res || '}';
        
    EXCEPTION
        WHEN OTHERS THEN
            -- إرجاع رسالة الخطأ
            RETURN '{"code":0,"msg":"' || DBMS_UTILITY.FORMAT_ERROR_STACK || '"}';
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
            created_date TIMESTAMP
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
BEGIN
    -- إعداد بيئة الاختبار
    cleanup_test;
    create_test_table;
    
    -- تعيين قيم جلسة افتراضية
    APEX_UTIL.SET_SESSION_STATE('P100_NAME', 'أحمد محمد');
    APEX_UTIL.SET_SESSION_STATE('P100_SALARY', 5000);
    APEX_UTIL.SET_SESSION_STATE('P100_DEPARTMENT', 'المبيعات');
    APEX_UTIL.SET_SESSION_STATE('APP_USER', 'TEST_USER');
    
    -- اختبار إضافة سجل جديد
    vr_res := MW.MAIN(
        p_row_status  => 'I',
        p_object_type => 'table',
        p_object_name => 'TEST_TABLE',
        p_items_list  => 'P100_NAME,P100_SALARY,P100_DEPARTMENT,CREATED_BY[:APP_USER],CREATED_DATE[SYSTIMESTAMP]',
        p_condition   => NULL
    );
    
    DBMS_OUTPUT.PUT_LINE('نتيجة الإضافة: ' || vr_res);
    
    -- استخراج الـ GUID من النتيجة
    DECLARE
        v_guid VARCHAR2(100);
    BEGIN
        v_guid := JSON_VALUE(vr_res, '$.data');
        DBMS_OUTPUT.PUT_LINE('GUID المولّد: ' || v_guid);
        
        -- اختبار تحديث السجل
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
    END;
    
    -- التنظيف بعد الاختبار
    cleanup_test;
END;
/

-------------------------------------------
-- 4. مثال استخدام في شاشة APEX
-------------------------------------------

/*
DECLARE
    vr_res       CLOB; 
    vr_condition VARCHAR2(500); 
BEGIN
    -- بناء الشرط
    vr_condition := 'GUID = ''' || :P188_GUID || '''';
    
    -- استدعاء الدالة الرئيسية
    vr_res := MW.MAIN(
        p_row_status  => :APEX$ROW_STATUS,
        p_object_type => 'table',
        p_object_name => MW.MASK('CUR_OPENNING','PI'),
        p_items_list  => 'P188_GUID,ORG_ID[:G_ORG_ID],P188_PAPER_NO,P188_SEARIAL_NO,' ||
                         'P188_SEQUENCE_NO,P188_ACTION_DATE,P188_PROJECT_ID,' ||
                         'P188_BRANCH_ID,P188_DESCRIPTION,P188_TRANSECTION_ID,' ||
                         'U_USER[:APP_USER],U_DATE[SYSTIMESTAMP],LVL[:G_LVL],' ||
                         'PROCESS_CAT[:P0_CAT],PROCESS_STAGE[:P0_STAGE]',
        p_condition   => vr_condition
    );
    
    -- معالجة النتيجة للسجلات الجديدة
    IF :APEX$ROW_STATUS = 'I' AND JSON_VALUE(vr_res, '$.data') IS NOT NULL THEN
        -- الطريقة الأولى: استخدام المتغير العام
        :P188_ACTION_ID := MW.G_global_id;
        
        -- الطريقة الثانية: الاستعلام من الجدول
        /*
        EXECUTE IMMEDIATE 
            'SELECT ACTION_ID FROM ' || MW.MASK('CUR_OPENNING','PI') ||
            ' WHERE guid = :guid'
            INTO :P188_ACTION_ID
            USING JSON_VALUE(vr_res, '$.data');
        */
    END IF;
    
    -- عرض رسالة النجاح
    APEX_JSON.PARSE(vr_res);
    IF APEX_JSON.GET_NUMBER('code') = 1 THEN
        APEX_UTIL.SET_SESSION_STATE('G_SUCCESS_MESSAGE', APEX_JSON.GET_VARCHAR2('msg'));
    ELSE
        APEX_UTIL.SET_SESSION_STATE('G_ERROR_MESSAGE', APEX_JSON.GET_VARCHAR2('msg'));
    END IF;
END;
*/