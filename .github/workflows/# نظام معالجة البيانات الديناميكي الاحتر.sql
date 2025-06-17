# نظام معالجة البيانات الديناميكي الاحترافي لأوراكل APEX 19c

## مقدمة
أقدم لك نظامًا متكاملًا لمعالجة البيانات الديناميكية في أوراكل APEX 19c، مصمم لمساعدة المطورين على بناء تطبيقات فعالة وقابلة للتطوير بسرعة. هذا النظام يجمع بين المرونة والقوة وسهولة الاستخدام.

## المكونات الأساسية للنظام

### 1. هيكل الجداول الأساسية

```sql
-- جدول تتبع العمليات
CREATE TABLE sys_operations (
    operation_id     RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    table_name       VARCHAR2(100) NOT NULL,
    operation_type   VARCHAR2(1) NOT NULL, -- I: إدراج, U: تحديث, D: حذف
    operation_date   TIMESTAMP DEFAULT SYSTIMESTAMP,
    user_id          VARCHAR2(100) NOT NULL,
    app_id           NUMBER,
    page_id          NUMBER,
    record_id        RAW(16),
    sql_statement    CLOB,
    old_values       CLOB,
    new_values       CLOB
);

-- جدول إدارة سير العمل
CREATE TABLE sys_workflows (
    workflow_id      RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    workflow_name    VARCHAR2(100) NOT NULL,
    table_name       VARCHAR2(100) NOT NULL,
    description      VARCHAR2(4000),
    is_active        VARCHAR2(1) DEFAULT 'Y'
);

-- جدول حالات سير العمل
CREATE TABLE sys_workflow_states (
    state_id         RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    workflow_id      RAW(16) REFERENCES sys_workflows(workflow_id),
    record_id        RAW(16) NOT NULL,
    current_status   VARCHAR2(50) NOT NULL,
    previous_status  VARCHAR2(50),
    last_updated     TIMESTAMP DEFAULT SYSTIMESTAMP,
    last_updated_by  VARCHAR2(100)
);

-- جدول خطوات سير العمل
CREATE TABLE sys_workflow_steps (
    step_id          RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    workflow_id      RAW(16) REFERENCES sys_workflows(workflow_id),
    step_name        VARCHAR2(100) NOT NULL,
    step_order       NUMBER NOT NULL,
    required_role    VARCHAR2(100)
);

-- جدول الإخطارات
CREATE TABLE sys_notifications (
    notification_id  RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    workflow_id      RAW(16),
    record_id        RAW(16),
    message          VARCHAR2(1000) NOT NULL,
    recipient        VARCHAR2(100),
    sent_date        TIMESTAMP DEFAULT SYSTIMESTAMP,
    read_date        TIMESTAMP
);
```

### 2. حزمة المعالجة الرئيسية (DATA_PROCESSOR)

```sql
CREATE OR REPLACE PACKAGE data_processor AS

    -- معالجة ديناميكية للعمليات
    FUNCTION process_dml(
        p_table_name    IN VARCHAR2,
        p_operation     IN VARCHAR2, -- 'INSERT', 'UPDATE', 'DELETE'
        p_items_list    IN CLOB,     -- قائمة العناصر متعددة الأسطر
        p_condition     IN VARCHAR2 DEFAULT NULL
    ) RETURN RAW;
    
    -- إدارة سير العمل
    PROCEDURE start_workflow(
        p_workflow_name IN VARCHAR2,
        p_record_id     IN RAW
    );
    
    PROCEDURE update_workflow_state(
        p_record_id    IN RAW,
        p_new_status   IN VARCHAR2
    );
    
    -- التحقق من الصلاحيات
    FUNCTION check_permission(
        p_user_id      IN VARCHAR2,
        p_table_name   IN VARCHAR2,
        p_operation    IN VARCHAR2
    ) RETURN BOOLEAN;
    
    -- إرسال الإخطارات
    PROCEDURE send_notification(
        p_record_id    IN RAW,
        p_message      IN VARCHAR2,
        p_recipient    IN VARCHAR2
    );
    
    -- متغيرات النظام
    g_last_record_id RAW(16);

END data_processor;
/
```

### 3. تنفيذ الحزمة الرئيسية

```sql
CREATE OR REPLACE PACKAGE BODY data_processor AS

    FUNCTION process_dml(
        p_table_name    IN VARCHAR2,
        p_operation     IN VARCHAR2,
        p_items_list    IN CLOB,
        p_condition     IN VARCHAR2 DEFAULT NULL
    ) RETURN RAW IS
        
        v_sql         VARCHAR2(4000);
        v_columns     VARCHAR2(4000);
        v_values      VARCHAR2(4000);
        v_set_clause  VARCHAR2(4000);
        v_record_id   RAW(16);
        v_item_line   VARCHAR2(4000);
        v_item_name   VARCHAR2(100);
        v_item_value  VARCHAR2(4000);
        v_pos         NUMBER := 1;
        v_delim_pos   NUMBER;
        v_has_workflow BOOLEAN := FALSE;
        
    BEGIN
        -- معالجة قائمة العناصر متعددة الأسطر
        LOOP
            v_delim_pos := INSTR(p_items_list, CHR(10), v_pos);
            
            IF v_delim_pos = 0 THEN
                v_item_line := SUBSTR(p_items_list, v_pos);
                v_pos := LENGTH(p_items_list) + 1;
            ELSE
                v_item_line := SUBSTR(p_items_list, v_pos, v_delim_pos - v_pos);
                v_pos := v_delim_pos + 1;
            END IF;
            
            v_item_line := TRIM(v_item_line);
            
            IF v_item_line IS NULL THEN
                EXIT WHEN v_pos > LENGTH(p_items_list);
                CONTINUE;
            END IF;
            
            -- استخراج اسم العنصر وقيمته
            IF INSTR(v_item_line, '[') > 0 THEN
                v_item_name := TRIM(SUBSTR(v_item_line, 1, INSTR(v_item_line, '[') - 1));
                v_item_value := TRIM(SUBSTR(v_item_line, INSTR(v_item_line, '[') + 1, 
                                    INSTR(v_item_line, ']') - INSTR(v_item_line, '[') - 1));
            ELSE
                v_item_name := v_item_line;
                v_item_value := APEX_UTIL.GET_SESSION_STATE(v_item_line);
            END IF;
            
            -- معالجة القيم الخاصة
            IF v_item_value LIKE ':%' THEN
                v_item_value := APEX_UTIL.GET_SESSION_STATE(REPLACE(v_item_value, ':', ''));
            ELSIF v_item_value = 'SYSDATE' THEN
                v_item_value := 'SYSDATE';
            ELSIF v_item_value = 'SYSTIMESTAMP' THEN
                v_item_value := 'SYSTIMESTAMP';
            END IF;
            
            -- التحقق من وجود سير العمل
            IF UPPER(v_item_name) = 'HAS_WORKFLOW' AND UPPER(v_item_value) = 'Y' THEN
                v_has_workflow := TRUE;
            END IF;
            
            -- بناء أجزاء SQL
            CASE p_operation
                WHEN 'INSERT' THEN
                    v_columns := v_columns || v_item_name || ',';
                    v_values := v_values || '''' || v_item_value || ''',';
                WHEN 'UPDATE' THEN
                    v_set_clause := v_set_clause || v_item_name || ' = ''' || v_item_value || ''',';
            END CASE;
            
            EXIT WHEN v_pos > LENGTH(p_items_list);
        END LOOP;
        
        -- إزالة الفواصل الزائدة
        v_columns := RTRIM(v_columns, ',');
        v_values := RTRIM(v_values, ',');
        v_set_clause := RTRIM(v_set_clause, ',');
        
        -- بناء وتنفيذ SQL
        CASE p_operation
            WHEN 'INSERT' THEN
                v_sql := 'INSERT INTO ' || p_table_name || '(' || v_columns || ') VALUES (' || v_values || ')';
                EXECUTE IMMEDIATE v_sql;
                
                -- استرجاع معرف السجل
                EXECUTE IMMEDIATE 
                    'SELECT id FROM ' || p_table_name || 
                    ' WHERE ROWID = (SELECT MAX(ROWID) FROM ' || p_table_name || ')' 
                    INTO v_record_id;
                
                g_last_record_id := v_record_id;
                
                -- بدء سير العمل إذا مطلوب
                IF v_has_workflow THEN
                    start_workflow(p_table_name || '_WF', v_record_id);
                END IF;
                
            WHEN 'UPDATE' THEN
                v_sql := 'UPDATE ' || p_table_name || ' SET ' || v_set_clause || ' WHERE ' || p_condition;
                EXECUTE IMMEDIATE v_sql;
                
                -- استخراج معرف السجل من الشرط
                v_record_id := REGEXP_SUBSTR(p_condition, '[^=]+$');
                v_record_id := REPLACE(v_record_id, '''', '');
                
            WHEN 'DELETE' THEN
                v_sql := 'DELETE FROM ' || p_table_name || ' WHERE ' || p_condition;
                EXECUTE IMMEDIATE v_sql;
                
                -- استخراج معرف السجل من الشرط
                v_record_id := REGEXP_SUBSTR(p_condition, '[^=]+$');
                v_record_id := REPLACE(v_record_id, '''', '');
        END CASE;
        
        -- تسجيل العملية
        INSERT INTO sys_operations (
            table_name, operation_type, user_id, 
            app_id, page_id, record_id, sql_statement
        ) VALUES (
            p_table_name, p_operation, APEX_UTIL.GET_SESSION_STATE('APP_USER'),
            APEX_APPLICATION.G_FLOW_ID, APEX_APPLICATION.G_FLOW_STEP_ID,
            v_record_id, v_sql
        );
        
        RETURN v_record_id;
        
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20001, 'خطأ في المعالجة: ' || SQLERRM);
    END process_dml;
    
    -- إجراءات إدارة سير العمل
    PROCEDURE start_workflow(
        p_workflow_name IN VARCHAR2,
        p_record_id     IN RAW
    ) IS
    BEGIN
        INSERT INTO sys_workflow_states (
            workflow_id, record_id, current_status
        ) VALUES (
            (SELECT workflow_id FROM sys_workflows WHERE workflow_name = p_workflow_name),
            p_record_id, 'NEW'
        );
    END start_workflow;
    
    PROCEDURE update_workflow_state(
        p_record_id    IN RAW,
        p_new_status   IN VARCHAR2
    ) IS
    BEGIN
        UPDATE sys_workflow_states
        SET previous_status = current_status,
            current_status = p_new_status,
            last_updated = SYSTIMESTAMP,
            last_updated_by = APEX_UTIL.GET_SESSION_STATE('APP_USER')
        WHERE record_id = p_record_id;
    END update_workflow_state;
    
    -- باقي إجراءات الحزمة تنفذ بنفس المنطق

END data_processor;
/
```

## آليات العمل الأساسية

### 1. معالجة البيانات الديناميكية
- **نموذج الاستخدام**:
  ```sql
  DECLARE
      v_record_id RAW(16);
      v_items CLOB := 
          'ID
          NAME
          EMAIL
          CREATED_DATE[SYSDATE]
          HAS_WORKFLOW[Y]';
  BEGIN
      v_record_id := data_processor.process_dml(
          p_table_name => 'USERS',
          p_operation => 'INSERT',
          p_items_list => v_items
      );
  END;
  ```

### 2. إدارة سير العمل
- **بدء سير عمل جديد**:
  ```sql
  data_processor.start_workflow('USERS_WF', v_record_id);
  ```
  
- **تحديث حالة سير العمل**:
  ```sql
  data_processor.update_workflow_state(v_record_id, 'APPROVED');
  ```

### 3. نظام الإخطارات
- **إرسال إخطار**:
  ```sql
  data_processor.send_notification(
      p_record_id => v_record_id,
      p_message => 'يحتاج السجل إلى مراجعتك',
      p_recipient => 'manager@example.com'
  );
  ```

## أفضل الممارسات للتطوير

### 1. تصميم وحدات مستقلة
- فصل منطق العمل عن واجهة المستخدم
- إنشاء وحدات متخصصة لكل وظيفة
- استخدام واجهات برمجية واضحة

### 2. إدارة الأخطاء
- **تسجيل الأخطاء**:
  ```sql
  EXCEPTION
      WHEN OTHERS THEN
          INSERT INTO error_log (message, backtrace)
          VALUES (SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
  ```
  
- **إعادة رفع الأخطاء**:
  ```sql
  RAISE_APPLICATION_ERROR(-20001, 'خطأ مخصص: ' || SQLERRM);
  ```

### 3. تحسين الأداء
- استخدام الروابط في الاستعلامات الديناميكية
- تقليل استخدام `SELECT *`
- استخدام التقسيم للجداول الكبيرة
- إنشاء فهارس مناسبة

### 4. الأمان
- استخدام `DBMS_ASSERT` للتحقق من المدخلات
- تجنب الثغرات الأمنية مثل SQL Injection
- التحقق من الصلاحيات قبل تنفيذ العمليات
- تشفير البيانات الحساسة

## أمثلة عملية للتكامل مع APEX

### 1. معالجة نموذج في صفحة APEX
```sql
DECLARE
    v_record_id RAW(16);
    v_items CLOB;
BEGIN
    -- بناء قائمة العناصر من صفحة APEX
    v_items := 
        'P1_ID
        P1_NAME
        P1_EMAIL
        P1_PHONE
        P1_STATUS
        CREATED_BY[:APP_USER]
        CREATED_DATE[SYSDATE]
        HAS_WORKFLOW[Y]';
    
    -- معالجة العملية
    v_record_id := data_processor.process_dml(
        p_table_name => 'CUSTOMERS',
        p_operation => :APEX$ROW_STATUS,
        p_items_list => v_items,
        p_condition => 'ID = ' || :P1_ID
    );
    
    -- معالجة النتيجة
    IF :APEX$ROW_STATUS = 'CREATE' THEN
        :P1_ID := v_record_id;
        APEX_UTIL.SET_SESSION_STATE('G_SUCCESS_MESSAGE', 'تم إنشاء السجل بنجاح');
    ELSE
        APEX_UTIL.SET_SESSION_STATE('G_SUCCESS_MESSAGE', 'تم تحديث السجل بنجاح');
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        APEX_UTIL.SET_SESSION_STATE('G_ERROR_MESSAGE', SQLERRM);
END;
```

### 2. تكامل سير العمل مع صفحة APEX
```sql
BEGIN
    -- تغيير حالة سير العمل عند الضغط على زر الموافقة
    data_processor.update_workflow_state(:P1_RECORD_ID, 'APPROVED');
    
    -- إرسال إخطار
    data_processor.send_notification(
        p_record_id => :P1_RECORD_ID,
        p_message => 'تمت الموافقة على السجل ' || :P1_RECORD_ID,
        p_recipient => 'admin@example.com'
    );
    
    APEX_UTIL.SET_SESSION_STATE('G_SUCCESS_MESSAGE', 'تمت الموافقة بنجاح');
END;
```

## نصائح للتطوير المستقبلي

1. **توسيع نظام الصلاحيات**
   - إضافة أدوار متعددة
   - تحديد صلاحيات لكل دور
   - التحقق من الصلاحيات قبل العمليات الحساسة

2. **تحسين نظام الإخطارات**
   - دعم إخطارات داخل التطبيق
   - تكامل مع البريد الإلكتروني
   - إخطارات SMS

3. **إضافة تحليلات البيانات**
   - تقارير عن سير العمل
   - إحصائيات الأداء
   - تحليل زمن التنفيذ

4. **التكامل مع الأنظمة الخارجية**
   - واجهات REST API
   - تكامل مع أنظمة ERP وCRM
   - دعم تبادل البيانات مع أنظمة أخرى

5. **نظام النسخ الاحتياطي**
   - نسخ احتياطي تلقائي
   - استعادة البيانات بسهولة
   - إدارة الإصدارات للبيانات الهامة

## خاتمة
هذا النظام يوفر أساسًا متينًا لبناء تطبيقات احترافية على أوراكل APEX 19c، مع التركيز على:

1. **المرونة**: تصميم قابل للتكيف مع متطلبات مختلفة
2. **الكفاءة**: معالجة ديناميكية توفر الوقت والجهد
3. **الأمان**: حماية البيانات والتحكم في الوصول
4. **القابلية للتطوير**: هيكل يدعم النمو المستقبلي
5. **سهولة الصيانة**: وحدات منظمة وواضحة

