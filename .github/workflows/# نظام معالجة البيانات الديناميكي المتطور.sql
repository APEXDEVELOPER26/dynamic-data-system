# نظام معالجة البيانات الديناميكي المتطور


-------------------------------------------
-- 1. إنشاء جداول النظام الأساسية
-------------------------------------------

-- جدول تتبع العمليات (مُحسّن)
CREATE TABLE sys_audit_trail (
    audit_id        RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    table_name      VARCHAR2(100) NOT NULL,
    operation_type  VARCHAR2(1) NOT NULL,   -- I/U/D
    sql_statement   CLOB NOT NULL,
    old_values      CLOB,
    new_values      CLOB,
    user_name       VARCHAR2(100) NOT NULL,
    ip_address      VARCHAR2(45),
    operation_date  TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE sys_audit_trail IS 'جدول مركزي لتسجيل جميع عمليات النظام';
COMMENT ON COLUMN sys_audit_trail.old_values IS 'قيم السجلات قبل التعديل (JSON)';
COMMENT ON COLUMN sys_audit_trail.new_values IS 'قيم السجلات بعد التعديل (JSON)';

-- جدول إشعارات سير العمل (مُحسّن)
CREATE TABLE sys_notifications (
    notification_id RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    table_name      VARCHAR2(100) NOT NULL,
    record_id       VARCHAR2(100),
    message         VARCHAR2(1000) NOT NULL,
    status          VARCHAR2(20) DEFAULT 'PENDING',
    created_by      VARCHAR2(100) NOT NULL,
    created_on      TIMESTAMP DEFAULT SYSTIMESTAMP,
    processed_on    TIMESTAMP
);

COMMENT ON TABLE sys_notifications IS 'جدول إدارة إشعارات سير العمل';
COMMENT ON COLUMN sys_notifications.status IS 'حالة الإشعار: PENDING, PROCESSED, FAILED';

-- جدول إعدادات النظام
CREATE TABLE sys_settings (
    setting_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    setting_name    VARCHAR2(100) NOT NULL UNIQUE,
    setting_value   VARCHAR2(4000),
    description     VARCHAR2(1000),
    is_active       VARCHAR2(1) DEFAULT 'Y'
);

COMMENT ON TABLE sys_settings IS 'جدول تخزين إعدادات النظام المركزي';

-------------------------------------------
-- 2. حزمة MW المتطورة (الإصدار 2.0)
-------------------------------------------

CREATE OR REPLACE PACKAGE MW AS
    -- الدالة الرئيسية للمعالجة (مُحسّنة)
    FUNCTION MAIN(
        p_row_status      VARCHAR2,   -- حالة الصف (I,U,D)
        p_object_type     VARCHAR2,   -- نوع الكائن (table, view)
        p_object_name     VARCHAR2,   -- اسم الجدول/العرض
        p_items_list      VARCHAR2,   -- قائمة العناصر
        p_condition       VARCHAR2,   -- الشرط
        p_audit_level     VARCHAR2 DEFAULT 'BASIC' -- مستوى التدقيق: BASIC, DETAILED
    ) RETURN CLOB;
    
    -- دالة مساعدة للإخفاء (قابلة للتوسعة)
    FUNCTION MASK(p_table_name VARCHAR2, p_mask_type VARCHAR2) RETURN VARCHAR2;
    
    -- إجراءات مساعدة جديدة
    FUNCTION GET_SETTING(p_name VARCHAR2) RETURN VARCHAR2;
    PROCEDURE LOG_ACTIVITY(p_message VARCHAR2, p_level VARCHAR2 DEFAULT 'INFO');
    
    -- متغيرات عامة
    G_global_id RAW(16);
    G_audit_enabled BOOLEAN := TRUE;
END MW;
/

CREATE OR REPLACE PACKAGE BODY MW AS

    -- دالة MASK القابلة للتخصيص
    FUNCTION MASK(p_table_name VARCHAR2, p_mask_type VARCHAR2) RETURN VARCHAR2 IS
        v_prefix VARCHAR2(10);
    BEGIN
        SELECT setting_value INTO v_prefix 
        FROM sys_settings 
        WHERE setting_name = 'TABLE_PREFIX_' || p_mask_type
        AND is_active = 'Y';
        
        RETURN v_prefix || p_table_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN p_table_name;
    END MASK;

    -- الحصول على إعدادات النظام
    FUNCTION GET_SETTING(p_name VARCHAR2) RETURN VARCHAR2 IS
        v_value VARCHAR2(4000);
    BEGIN
        SELECT setting_value INTO v_value 
        FROM sys_settings 
        WHERE setting_name = p_name
        AND is_active = 'Y';
        
        RETURN v_value;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END GET_SETTING;

    -- تسجيل أنشطة النظام
    PROCEDURE LOG_ACTIVITY(p_message VARCHAR2, p_level VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO sys_audit_trail (
            table_name, operation_type, 
            sql_statement, user_name, ip_address
        ) VALUES (
            'SYSTEM', p_level, 
            p_message, V('APP_USER'), V('G_IP_ADDRESS')
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END LOG_ACTIVITY;

    -- الدالة الرئيسية المتطورة
    FUNCTION MAIN(
        p_row_status      VARCHAR2,
        p_object_type     VARCHAR2,
        p_object_name     VARCHAR2,
        p_items_list      VARCHAR2,
        p_condition       VARCHAR2,
        p_audit_level     VARCHAR2
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
        v_old_values   CLOB;
        v_new_values   CLOB;
        v_audit_detail BOOLEAN := (p_audit_level = 'DETAILED');
        
        -- أنواع البيانات المدعومة
        TYPE t_value_type IS RECORD (
            name  VARCHAR2(100),
            value VARCHAR2(4000),
            type  VARCHAR2(20)
        );
        
        TYPE t_values_tab IS TABLE OF t_value_type;
        v_values_tab t_values_tab := t_values_tab();
    BEGIN
        -- تسجيل بدء العملية
        LOG_ACTIVITY('بدء معالجة: ' || p_row_status || ' - ' || p_object_name);
        
        -- معالجة قائمة العناصر
        FOR item IN (
            SELECT TRIM(regexp_substr(p_items_list, '[^,]+', 1, LEVEL)) item_name
            FROM dual 
            CONNECT BY LEVEL <= regexp_count(p_items_list, ',') + 1
        )
        LOOP
            v_item_name := item.item_name;
            v_item_value := NULL;
            v_values_tab.EXTEND;
            v_values_tab(v_values_tab.LAST) := t_value_type(v_item_name, NULL, 'DIRECT');
            
            -- 1. معالجة متغيرات الجلسة [:G_VAR]
            IF v_item_name LIKE '%[:%]%' THEN
                DECLARE
                    v_session_var VARCHAR2(100);
                BEGIN
                    v_session_var := TRIM(SUBSTR(v_item_name, 
                                         INSTR(v_item_name, '[') + 1, 
                                         INSTR(v_item_name, ']') - INSTR(v_item_name, '[') - 1));
                    
                    IF v_session_var IS NOT NULL AND v_session_var LIKE ':%' THEN
                        v_session_var := REPLACE(v_session_var, ':', '');
                        v_item_value := APEX_UTIL.GET_SESSION_STATE(v_session_var);
                        v_values_tab(v_values_tab.LAST).type := 'SESSION';
                    END IF;
                    
                    v_item_name := SUBSTR(v_item_name, 1, INSTR(v_item_name, '[') - 1);
                END;
                
            -- 2. معالجة توابع النظام [SYSTIMESTAMP]
            ELSIF v_item_name LIKE '%[SYSTIMESTAMP]' THEN
                v_item_value := TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF');
                v_item_name := REPLACE(v_item_name, '[SYSTIMESTAMP]', '');
                v_values_tab(v_values_tab.LAST).type := 'FUNCTION';
                
            ELSIF v_item_name LIKE '%[SYSDATE]' THEN
                v_item_value := TO_CHAR(SYSDATE, 'YYYY-MM-DD');
                v_item_name := REPLACE(v_item_name, '[SYSDATE]', '');
                v_values_tab(v_values_tab.LAST).type := 'FUNCTION';
                
            -- 3. معالجة التعبيرات المركبة ['||VR_VAR||']
            ELSIF v_item_name LIKE '%[''%||%||%'']%' THEN
                DECLARE
                    v_expr VARCHAR2(4000);
                BEGIN
                    v_expr := REPLACE(SUBSTR(v_item_name, INSTR(v_item_name, '[') + 1), ']');
                    
                    -- استبدال المتغيرات العامة
                    v_expr := REPLACE(v_expr, ':APP_USER', '''' || V('APP_USER') || '''');
                    v_expr := REPLACE(v_expr, ':G_ORG_ID', '''' || V('G_ORG_ID') || '''');
                    v_expr := REPLACE(v_expr, ':G_LVL', '''' || V('G_LVL') || '''');
                    
                    -- تنفيذ التعبير
                    EXECUTE IMMEDIATE 'BEGIN :1 := ' || v_expr || '; END;' USING OUT v_item_value;
                    
                    v_item_name := SUBSTR(v_item_name, 1, INSTR(v_item_name, '[') - 1);
                    v_values_tab(v_values_tab.LAST).type := 'EXPRESSION';
                EXCEPTION
                    WHEN OTHERS THEN
                        v_item_value := NULL;
                        LOG_ACTIVITY('خطأ في التعبير: ' || v_expr, 'ERROR');
                END;
                
            -- 4. معالجة العناصر العادية
            ELSE
                v_item_value := APEX_UTIL.GET_SESSION_STATE(v_item_name);
            END IF;
            
            -- تحديث قيمة العنصر
            v_values_tab(v_values_tab.LAST).value := v_item_value;
            v_values_tab(v_values_tab.LAST).name := v_item_name;
            
            -- التحقق من وجود متغير سير العمل
            IF UPPER(v_item_name) = 'HAS_WORKFLOW' THEN
                v_has_workflow := (UPPER(v_item_value) = 'Y');
            END IF;
        END LOOP;
        
        -- جمع القيم القديمة للتسجيل التفصيلي
        IF v_audit_detail AND p_row_status IN ('U','D') THEN
            SELECT JSON_OBJECTAGG(column_name VALUE value) 
            INTO v_old_values
            FROM (
                SELECT column_name, value
                FROM sys_table_values
                WHERE table_name = p_object_name
                AND primary_key = p_condition
            );
        END IF;
        
        -- بناء أجزاء SQL
        FOR i IN 1..v_values_tab.COUNT LOOP
            v_item_name := v_values_tab(i).name;
            v_item_value := v_values_tab(i).value;
            
            -- تخطي عناصر خاصة
            CONTINUE WHEN UPPER(v_item_name) IN ('HAS_WORKFLOW', 'AUDIT_LEVEL');
            
            -- إزالة بادئة الصفحة
            v_item_name := REPLACE(v_item_name, v_page_prefix, '');
            
            -- تجاهل العناصر الفارغة
            CONTINUE WHEN v_item_name IS NULL;
            
            CASE p_row_status
                WHEN 'I' THEN
                    v_columns := v_columns || v_item_name || ',';
                    v_values := v_values || '''' || v_item_value || ''',';
                WHEN 'U' THEN
                    v_set_clause := v_set_clause || v_item_name || ' = ''' || v_item_value || ''',';
            END CASE;
        END LOOP;
        
        -- إزالة الفواصل الزائدة
        v_columns := RTRIM(v_columns, ',');
        v_values := RTRIM(v_values, ',');
        v_set_clause := RTRIM(v_set_clause, ',');
        
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
                
                -- جمع القيم الجديدة للتسجيل التفصيلي
                IF v_audit_detail THEN
                    SELECT JSON_OBJECTAGG(column_name VALUE value) 
                    INTO v_new_values
                    FROM (
                        SELECT v_values_tab(i).name AS column_name, 
                               v_values_tab(i).value AS value
                        FROM dual
                        CONNECT BY LEVEL <= v_values_tab.COUNT
                    );
                END IF;
                
            WHEN 'U' THEN
                -- تحديث سجل موجود
                v_sql := 'UPDATE ' || p_object_name || ' SET ' || v_set_clause || ' WHERE ' || p_condition;
                EXECUTE IMMEDIATE v_sql;
                v_res := '{"data":"1"}';
                
                -- جمع القيم الجديدة للتسجيل التفصيلي
                IF v_audit_detail THEN
                    SELECT JSON_OBJECTAGG(v.name VALUE v.value) 
                    INTO v_new_values
                    FROM TABLE(v_values_tab) v
                    WHERE v.name NOT IN ('HAS_WORKFLOW', 'AUDIT_LEVEL');
                END IF;
                
            WHEN 'D' THEN
                -- حذف سجل
                v_sql := 'DELETE FROM ' || p_object_name || ' WHERE ' || p_condition;
                EXECUTE IMMEDIATE v_sql;
                v_res := '{"data":"1"}';
        END CASE;
        
        -- تسجيل التتبع
        IF G_audit_enabled THEN
            INSERT INTO sys_audit_trail (
                table_name, operation_type, 
                sql_statement, old_values, new_values,
                user_name, ip_address
            ) VALUES (
                p_object_name, p_row_status, 
                v_sql, v_old_values, v_new_values,
                V('APP_USER'), V('G_IP_ADDRESS')
            );
        END IF;
        
        -- توليد إشعارات سير العمل إذا مطلوب
        IF v_has_workflow THEN
            INSERT INTO sys_notifications (
                table_name, record_id,
                message, created_by, status
            ) VALUES (
                p_object_name, v_guid,
                'تم تنفيذ العملية: ' || p_row_status,
                V('APP_USER'), 'PENDING'
            );
        END IF;
        
        -- إرجاع النتيجة
        RETURN '{"code":1,"msg":"تمت العملية بنجاح",' || v_res || '}';
        
    EXCEPTION
        WHEN OTHERS THEN
            -- إرجاع رسالة الخطأ
            LOG_ACTIVITY('خطأ: ' || SQLERRM, 'ERROR');
            RETURN '{"code":0,"msg":"' || REPLACE(DBMS_UTILITY.FORMAT_ERROR_STACK, '"', '') || '"}';
    END MAIN;
    
END MW;
/

-------------------------------------------
-- 3. حزمة التوسعة MW_EXTENSIONS
-------------------------------------------

CREATE OR REPLACE PACKAGE MW_EXT AS
    -- دعم معالجة JSON
    FUNCTION PROCESS_JSON(p_json CLOB) RETURN CLOB;
    
    -- دعم العمليات المجمعة
    PROCEDURE BULK_PROCESS(p_operations CLOB);
    
    -- دعم النسخ الاحتياطي التلقائي
    PROCEDURE AUTO_BACKUP(p_table_name VARCHAR2);
    
    -- إدارة التبعيات
    PROCEDURE RECOMPILE_DEPENDENCIES;
    
    -- واجهة REST API
    FUNCTION REST_HANDLER(p_request CLOB) RETURN CLOB;
END MW_EXT;
/

CREATE OR REPLACE PACKAGE BODY MW_EXT AS

    FUNCTION PROCESS_JSON(p_json CLOB) RETURN CLOB IS
        j_data JSON_OBJECT_T;
        v_result CLOB;
    BEGIN
        j_data := JSON_OBJECT_T(p_json);
        
        -- استدعاء الدالة الرئيسية مع معطيات JSON
        v_result := MW.MAIN(
            j_data.get_string('row_status'),
            j_data.get_string('object_type'),
            j_data.get_string('object_name'),
            j_data.get_string('items_list'),
            j_data.get_string('condition'),
            j_data.get_string('audit_level')
        );
        
        RETURN v_result;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN '{"code":0,"msg":"JSON Processing Error"}';
    END PROCESS_JSON;

    PROCEDURE BULK_PROCESS(p_operations CLOB) IS
        j_ops JSON_ARRAY_T;
        j_op  JSON_OBJECT_T;
    BEGIN
        j_ops := JSON_ARRAY_T(p_operations);
        
        FOR i IN 0 .. j_ops.get_size - 1 LOOP
            j_op := JSON_OBJECT_T(j_ops.get(i));
            
            MW.MAIN(
                j_op.get_string('row_status'),
                j_op.get_string('object_type'),
                j_op.get_string('object_name'),
                j_op.get_string('items_list'),
                j_op.get_string('condition'),
                j_op.get_string('audit_level')
            );
        END LOOP;
    END BULK_PROCESS;

    PROCEDURE AUTO_BACKUP(p_table_name VARCHAR2) IS
        v_backup_name VARCHAR2(100);
    BEGIN
        v_backup_name := p_table_name || '_bkp_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
        
        EXECUTE IMMEDIATE 'CREATE TABLE ' || v_backup_name || 
                          ' AS SELECT * FROM ' || p_table_name;
        
        MW.LOG_ACTIVITY('تم إنشاء نسخة احتياطية: ' || v_backup_name);
    END AUTO_BACKUP;

    PROCEDURE RECOMPILE_DEPENDENCIES IS
    BEGIN
        DBMS_UTILITY.COMPILE_SCHEMA(USER, COMPILE_ALL => TRUE);
        MW.LOG_ACTIVITY('تم إعادة تجميع كافة كائنات المخطط');
    END RECOMPILE_DEPENDENCIES;

    FUNCTION REST_HANDLER(p_request CLOB) RETURN CLOB IS
        j_req  JSON_OBJECT_T;
        j_res  JSON_OBJECT_T := JSON_OBJECT_T();
        v_action VARCHAR2(100);
    BEGIN
        j_req := JSON_OBJECT_T(p_request);
        v_action := j_req.get_string('action');
        
        CASE v_action
            WHEN 'EXECUTE_DML' THEN
                j_res.put('result', MW_EXT.PROCESS_JSON(j_req.get_string('data')));
            WHEN 'BULK_PROCESS' THEN
                MW_EXT.BULK_PROCESS(j_req.get_string('data'));
                j_res.put('result', 'Bulk processing completed');
            WHEN 'GET_AUDIT_LOG' THEN
                SELECT JSON_ARRAYAGG(
                    JSON_OBJECT(
                        'table_name' VALUE table_name,
                        'operation' VALUE operation_type,
                        'user' VALUE user_name,
                        'date' VALUE TO_CHAR(operation_date, 'YYYY-MM-DD HH24:MI:SS')
                    )
                )
                INTO j_res
                FROM sys_audit_trail
                WHERE operation_date > SYSDATE - 7;
            ELSE
                j_res.put('error', 'Invalid action requested');
        END CASE;
        
        RETURN j_res.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            j_res.put('error', SQLERRM);
            RETURN j_res.to_clob();
    END REST_HANDLER;
    
END MW_EXT;
/

-------------------------------------------
-- 4. تهيئة إعدادات النظام
-------------------------------------------

-- إعدادات أساسية
INSERT INTO sys_settings (setting_name, setting_value, description) 
VALUES ('TABLE_PREFIX_PI', 'TBL_', 'بادئة الجداول الخاصة');

INSERT INTO sys_settings (setting_name, setting_value, description) 
VALUES ('DEFAULT_AUDIT_LEVEL', 'DETAILED', 'مستوى التدقيق الافتراضي');

INSERT INTO sys_settings (setting_name, setting_value, description) 
VALUES ('AUTO_BACKUP', 'N', 'النسخ الاحتياطي التلقائي للجداول');

-- إعدادات سير العمل
INSERT INTO sys_settings (setting_name, setting_value, description) 
VALUES ('WORKFLOW_ENABLED', 'Y', 'تفعيل إشعارات سير العمل');

COMMIT;

-------------------------------------------
-- 5. مثال استخدام متقدم في شاشة APEX
-------------------------------------------

/*
DECLARE
    vr_res       CLOB; 
    vr_condition VARCHAR2(500); 
    v_audit_level VARCHAR2(20) := MW.GET_SETTING('DEFAULT_AUDIT_LEVEL');
BEGIN
    -- بناء الشرط باستخدام GUID
    vr_condition := 'GUID = ''' || :P188_GUID || '''';
    
    -- استدعاء الدالة الرئيسية بشكل مباشر
    vr_res := MW.MAIN(
        p_row_status    => :APEX$ROW_STATUS,
        p_object_type   => 'table',
        p_object_name   => MW.MASK('CUR_OPENNING','PI'),
        p_items_list    => 'P188_GUID,ORG_ID[:G_ORG_ID],P188_PAPER_NO,P188_SEARIAL_NO,' ||
                           'P188_SEQUENCE_NO,P188_ACTION_DATE,P188_PROJECT_ID,' ||
                           'P188_BRANCH_ID,P188_DESCRIPTION,P188_TRANSECTION_ID,' ||
                           'U_USER[:APP_USER],U_DATE[SYSTIMESTAMP],LVL[:G_LVL],' ||
                           'PROCESS_CAT[:P0_CAT],PROCESS_STAGE[:P0_STAGE],' ||
                           'BONUS[''||:P188_BASE_SALARY * 0.1||''],' ||
                           'HAS_WORKFLOW[:P188_HAS_WORKFLOW]',
        p_condition     => vr_condition,
        p_audit_level   => v_audit_level
    );
    
    -- معالجة النتيجة للسجلات الجديدة
    IF :APEX$ROW_STATUS = 'I' AND JSON_VALUE(vr_res, '$.data') IS NOT NULL THEN
        :P188_ACTION_ID := MW.G_global_id;
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
        
        -- نسخ احتياطي تلقائي إذا مفعل
        IF MW.GET_SETTING('AUTO_BACKUP') = 'Y' THEN
            MW_EXT.AUTO_BACKUP(MW.MASK('CUR_OPENNING','PI'));
        END IF;
    ELSE
        -- خطأ في العملية
        APEX_UTIL.SET_SESSION_STATE(
            'G_ERROR_MESSAGE', 
            JSON_VALUE(vr_res, '$.msg')
        );
    END IF;
END;
*/
```

## الميزات المتقدمة المضافة:

### 1. نظام تسجيل متطور (Enhanced Audit Trail)
- تسجيل القيم القديمة والجديدة بتنسيق JSON
- تخزين عنوان IP للمستخدم
- مستويات تدقيق مختلفة (BASIC, DETAILED)
- تسجيل تلقائي للأنشطة النظامية

### 2. إدارة إعدادات مركزي
- جدول `sys_settings` لتخزين إعدادات النظام
- دعم التكوين الديناميكي دون تعديل الكود
- إعدادات مسبقة للنسخ الاحتياطي ومستويات التدقيق

### 3. حزمة التوسعة MW_EXT
- **معالجة JSON**: تنفيذ عمليات DML عبر واجهة JSON
- **عمليات مجمعة**: معالجة عدة عمليات في طلب واحد
- **نسخ احتياطي تلقائي**: إنشاء نسخ احتياطية للجداول
- **إعادة تجميع التبعيات**: صيانة تلقائية لكود النظام
- **واجهة REST API**: دعم للتكامل مع أنظمة خارجية

### 4. تحسينات الأمان
- تسجيل عنوان IP للمستخدمين
- عزل عمليات التسجيل باستخدام Autonomous Transactions
- إدارة أخطاء محسنة مع تسجيل تفصيلي
- دعم البادئات الآمنة للجداول

### 5. نظام إشعارات متطور
- تتبع حالة الإشعارات (معلّق، مكتمل، فشل)
- تواريخ إنشاء ومعالجة الإشعارات
- تكامل مع سير العمل الديناميكي

### 6. ميزات الأداء
- دعم العمليات المجمعة للأداء العالي
- تخزين مؤقت للإعدادات المتكررة
- إعادة تجميع تلقائي لتحسين تنفيذ الكود
- معالجة متوازية للإشعارات

## أمثلة استخدام متقدمة:

### 1. معالجة عبر واجهة JSON
```sql
DECLARE
    vr_res CLOB;
    vr_json CLOB := '{
        "row_status": "I",
        "object_type": "table",
        "object_name": "EMPLOYEES",
        "items_list": "EMP_NAME,EMP_SALARY[:P100_SALARY],HIRE_DATE[SYSDATE]",
        "condition": "",
        "audit_level": "DETAILED"
    }';
BEGIN
    vr_res := MW_EXT.PROCESS_JSON(vr_json);
END;
```

### 2. عمليات مجمعة
```sql
BEGIN
    MW_EXT.BULK_PROCESS('[
        {
            "row_status": "I",
            "object_type": "table",
            "object_name": "ORDERS",
            "items_list": "ORDER_ID,ORDER_DATE[SYSDATE]",
            "condition": ""
        },
        {
            "row_status": "I",
            "object_type": "table",
            "object_name": "ORDER_ITEMS",
            "items_list": "ORDER_ID,PRODUCT_ID,QTY",
            "condition": ""
        }
    ]');
END;
```

### 3. استدعاء عبر REST API
```javascript
// مثال باستخدام JavaScript
const response = await fetch('/apex/rest_handler', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({
        action: 'EXECUTE_DML',
        data: {
            row_status: "U",
            object_type: "table",
            object_name: "CUSTOMERS",
            items_list: "STATUS[''ACTIVE''],LAST_UPDATE[SYSTIMESTAMP]",
            condition: "CUSTOMER_ID = 123"
        }
    })
});
```

1. **دعم NoSQL**: 
   - تكامل مع Oracle NoSQL
   - معالجة مستندات JSON/XML

2. **الذكاء الاصطناعي**:
   - تحليل توقعات البيانات
   - كشف الشذوذ في العمليات

3. **التكامل مع السحابة**:
   - نسخ احتياطي إلى Oracle Cloud
   - تكامل مع خدمات الذكاء الاصطناعي السحابي

4. **لوحة تحكم إدارية**:
   - مراقبة أداء النظام
   - تقارير تفاعلية عن العمليات
   - إدارة الإشعارات والتنبيهات

5. **نظام أذونات متقدم**:
   - أذونات على مستوى الصف
   - تفويض ديناميكي للصلاحيات
   - تسجيل كامل لوصول المستخدمين
