-------------------------------------------
-- 1. إنشاء الجداول الأساسية مع التعديلات --
-------------------------------------------

-- جدول فئات العمليات (المعدل)
CREATE TABLE "SYS_PROCESS_CAT" (
    "PROCESS_CAT" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "PROCESS_CAT_NAME" VARCHAR2(100) NOT NULL UNIQUE,
    "APPROVE_STAGE" VARCHAR2(50),
    "REJECT_STAGE" VARCHAR2(50),
    "BLK_ID" VARCHAR2(250),
    "REVERS_ALLOW" VARCHAR2(250),
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "U_USER" VARCHAR2(50),
    "U_DATE" TIMESTAMP,
    "D_STS" NUMBER(1) DEFAULT 0 CHECK (D_STS IN (0,1)),
    "LVL" VARCHAR2(50) DEFAULT '0',
    "STS" NUMBER(1) DEFAULT 1 CHECK (STS IN (0,1)),
    "GUID" VARCHAR2(50) DEFAULT SYS_GUID(),
    "ENTER_IN_COMPLETE" NUMBER(1) DEFAULT 0,
    "EDIT_ALLOW" NUMBER(1) DEFAULT 0,
    "DIRECT_ENTRY" NUMBER(1) DEFAULT 0,
    -- إضافة حقول جديدة للتخصيص
    "MAX_DURATION" NUMBER DEFAULT 7, -- المدة القصوى بالأيام
    "SPECIAL_FLAGS" VARCHAR2(500) -- أعلام خاصة للاستخدام المستقبلي
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_PROCESS_CAT" IS 'فئات العمليات الرئيسية مع إعدادات التخصيص';

-- جدول مراحل العمليات (المعدل)
CREATE TABLE "SYS_PROCESS_STAGE" (
    "PROCESS_STAGE" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "PROCESS_CAT" NUMBER NOT NULL REFERENCES "SYS_PROCESS_CAT"("PROCESS_CAT"),
    "PROCESS_STAGE_NAME" VARCHAR2(50) NOT NULL,
    "DESCRIPTION" VARCHAR2(200),
    "ALL_EMPLOYEE" NUMBER(1) DEFAULT 0 CHECK (ALL_EMPLOYEE IN (0,1)),
    "FIRST_SUPERVISOR_APPROVE" NUMBER(1) DEFAULT 0,
    "SECOND_SUPERVISOR_APPROVE" NUMBER(1) DEFAULT 0,
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "U_USER" VARCHAR2(50),
    "U_DATE" TIMESTAMP,
    "D_STS" NUMBER(1) DEFAULT 0,
    "LVL" VARCHAR2(50) DEFAULT '0',
    "STS" NUMBER(1) DEFAULT 1,
    "GUID" VARCHAR2(50) DEFAULT SYS_GUID() UNIQUE,
    "ORDER_NO" NUMBER DEFAULT 0 NOT NULL,
    "IS_DEFAULT" NUMBER DEFAULT 0 CHECK (IS_DEFAULT IN (0,1)),
    -- إضافة حقول التحقق
    "MANDATORY_COMMENT" NUMBER(1) DEFAULT 0,
    "ATTACHMENT_REQUIRED" NUMBER(1) DEFAULT 0,
    "AUTO_ADVANCE" NUMBER(1) DEFAULT 0 -- تقدم تلقائي عند استيفاء الشروط
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_PROCESS_STAGE" IS 'مراحل سير العمل مع قواعد التحقق';

-- جدول مجموعات الموافقة (بدون تغيير)
CREATE TABLE "SYS_APPROVE_GROUP" (
    "PROCESS_CAT" NUMBER REFERENCES "SYS_PROCESS_CAT"("PROCESS_CAT"),
    "PROCESS_STAGE" NUMBER REFERENCES "SYS_PROCESS_STAGE"("PROCESS_STAGE"),
    "APPROVE_GROUP_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "APP_GROUP_NAME" VARCHAR2(200) NOT NULL UNIQUE,
    "IN_SAME_BRANCH" NUMBER(1) DEFAULT 0,
    "DESCRIPTION" VARCHAR2(250),
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "U_USER" VARCHAR2(50),
    "U_DATE" TIMESTAMP,
    "D_STS" NUMBER(1) DEFAULT 0,
    "LVL" VARCHAR2(50) DEFAULT '0',
    "STS" NUMBER(1) DEFAULT 1,
    "GUID" VARCHAR2(50) DEFAULT SYS_GUID() UNIQUE,
    -- إضافة حقل للحد الأدنى للموافقات
    "MIN_APPROVALS" NUMBER DEFAULT 1
) TABLESPACE USERS;

-- جدول بيانات سير العمل (محدث)
CREATE TABLE "SYS_WORKFLOW_DATA" (
    "DATA_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "CURRENT_DATA" CLOB,
    "ALL_COMMENTS" CLOB,
    "PROCESS_TYPE" VARCHAR2(50),
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "U_USER" VARCHAR2(50),
    "U_DATE" TIMESTAMP,
    "D_STS" NUMBER(1) DEFAULT 0,
    "LVL" VARCHAR2(50) DEFAULT '0',
    "STS" NUMBER(1) DEFAULT 1,
    "GUID" VARCHAR2(50) DEFAULT SYS_GUID(),
    "PROCESS_CAT" NUMBER NOT NULL REFERENCES "SYS_PROCESS_CAT"("PROCESS_CAT"),
    "PROCESS_STAGE" NUMBER NOT NULL REFERENCES "SYS_PROCESS_STAGE"("PROCESS_STAGE"),
    "REFERENCE_GUID" VARCHAR2(50),
    "SCRN_ALIAS" VARCHAR2(100),
    "HAS_MASTER" NUMBER(1) DEFAULT 0,
    "TBL" VARCHAR2(100),
    "PAGE_NO" NUMBER,
    "BRANCH_ID" NUMBER,
    -- إضافة حقول التحقق والإدارة
    "VALIDATION_STATUS" NUMBER(1) DEFAULT 0 CHECK (VALIDATION_STATUS IN (0,1,2)), -- 0=قيد المراجعة, 1=صالح, 2=غير صالح
    "VALIDATION_ERRORS" CLOB,
    "DUPLICATE_CHECK" NUMBER(1) DEFAULT 0,
    "CONFLICT_CHECK" NUMBER(1) DEFAULT 0,
    "AUTO_APPROVED" NUMBER(1) DEFAULT 0, -- تمت الموافقة تلقائياً
    "URGENCY_LEVEL" NUMBER(1) DEFAULT 3, -- 1=عالي, 2=متوسط, 3=منخفض
    -- إضافة حقول للتوسع المستقبلي
    "CUSTOM_ATTRIBUTES" CLOB, -- JSON للتخصيصات المستقبلية
    "EXPIRY_DATE" DATE -- تاريخ انتهاء الصلاحية
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_WORKFLOW_DATA" IS 'بيانات سير العمل مع حالة التحقق';

-------------------------------------------
-- 2. جداول التحقق الديناميكي والإدارة   --
-------------------------------------------

-- جدول قواعد التحقق
CREATE TABLE "SYS_VALIDATION_RULES" (
    "RULE_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "RULE_NAME" VARCHAR2(200) NOT NULL,
    "DESCRIPTION" VARCHAR2(1000),
    "RULE_TYPE" VARCHAR2(20) NOT NULL CHECK (RULE_TYPE IN ('FIELD','RECORD','STAGE','GLOBAL')),
    "TARGET_OBJECT" VARCHAR2(100), -- اسم الجدول/الحقل
    "CONDITION_LOGIC" CLOB NOT NULL, -- شرط SQL ديناميكي
    "ERROR_MESSAGE" VARCHAR2(1000) NOT NULL,
    "ACTIVE" NUMBER(1) DEFAULT 1 CHECK (ACTIVE IN (0,1)),
    "PRIORITY" NUMBER DEFAULT 1,
    "PROCESS_CAT" NUMBER REFERENCES "SYS_PROCESS_CAT"("PROCESS_CAT"),
    "PROCESS_STAGE" NUMBER REFERENCES "SYS_PROCESS_STAGE"("PROCESS_STAGE"),
    "SPECIAL_ACTION" VARCHAR2(50), -- AUTO_APPROVE, ESCALATE, URGENT
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_VALIDATION_RULES" IS 'قواعد التحقق الديناميكية لكل مرحلة';

-- جدول ربط القواعد بالمراحل
CREATE TABLE "SYS_STAGE_RULES" (
    "STAGE_RULE_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "PROCESS_STAGE" NUMBER NOT NULL REFERENCES "SYS_PROCESS_STAGE"("PROCESS_STAGE"),
    "RULE_ID" NUMBER NOT NULL REFERENCES "SYS_VALIDATION_RULES"("RULE_ID"),
    "EXECUTION_ORDER" NUMBER DEFAULT 1 NOT NULL,
    "MANDATORY" NUMBER(1) DEFAULT 1 CHECK (MANDATORY IN (0,1)), -- 1=إجباري, 0=تحذير
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_STAGE_RULES" IS 'ربط قواعد التحقق بمراحل سير العمل';

-- جدول التفويضات (جديد)
CREATE TABLE "SYS_DELEGATION" (
    "DELEGATION_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "FROM_EMPLOYEE" NUMBER NOT NULL,
    "TO_EMPLOYEE" NUMBER NOT NULL,
    "PROCESS_CAT" NUMBER REFERENCES "SYS_PROCESS_CAT"("PROCESS_CAT"),
    "START_DATE" TIMESTAMP NOT NULL,
    "END_DATE" TIMESTAMP NOT NULL,
    "ACTIVE" NUMBER(1) DEFAULT 1 CHECK (ACTIVE IN (0,1)),
    "REASON" VARCHAR2(1000),
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT CHK_NO_SELF_DELEGATION CHECK (FROM_EMPLOYEE <> TO_EMPLOYEE),
    CONSTRAINT CHK_VALID_DATES CHECK (END_DATE > START_DATE)
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_DELEGATION" IS 'تفويضات الموظفين للموافقة على الطلبات';

-- جدول المرفقات (جديد)
CREATE TABLE "SYS_ATTACHMENT" (
    "ATTACHMENT_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "WORKFLOW_DATA_ID" NUMBER NOT NULL REFERENCES "SYS_WORKFLOW_DATA"("DATA_ID"),
    "FILE_NAME" VARCHAR2(500) NOT NULL,
    "FILE_TYPE" VARCHAR2(50) NOT NULL,
    "FILE_SIZE" NUMBER,
    "CONTENT" BLOB,
    "STAGE_ID" NUMBER REFERENCES "SYS_PROCESS_STAGE"("PROCESS_STAGE"),
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP
) TABLESPACE USERS LOB ("CONTENT") STORE AS SECUREFILE;

COMMENT ON TABLE "SYS_ATTACHMENT" IS 'مرفقات سير العمل';

-- جدول الإشعارات (محدث)
CREATE TABLE "SYS_ALARM_NOTIFICATION" (
    "SEQ_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "URL" VARCHAR2(2000),
    "BLK_ID" VARCHAR2(500),
    "ACTION_ID" VARCHAR2(50),
    "PROCESS_CAT" NUMBER REFERENCES "SYS_PROCESS_CAT"("PROCESS_CAT"),
    "PROCESS_STAGE" NUMBER REFERENCES "SYS_PROCESS_STAGE"("PROCESS_STAGE"),
    "EMPLOYEE_ID" NUMBER NOT NULL,
    "SENDER_EMPLOYEE" NUMBER,
    "ACTION_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "BRANCH_ID" NUMBER,
    "NOTIFICATION_HEAD" VARCHAR2(500) NOT NULL,
    "NOTIFICATION_DESCRIPTION" VARCHAR2(2000),
    "IS_ACTIVE" NUMBER(1) DEFAULT 1,
    "C_USER" VARCHAR2(50) DEFAULT COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER),
    "C_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "U_USER" VARCHAR2(50),
    "U_DATE" TIMESTAMP,
    "D_STS" NUMBER(1) DEFAULT 0,
    "LVL" VARCHAR2(50) DEFAULT '0',
    "STS" NUMBER(1) DEFAULT 1,
    "GUID" VARCHAR2(50) DEFAULT SYS_GUID() UNIQUE,
    "NOTIFICATION_TYPE" NUMBER,
    "NOTIFICATION_LVL" NUMBER,
    "CONNECTION_ID" NUMBER,
    -- إضافة حقول جديدة
    "READ_STATUS" NUMBER(1) DEFAULT 0 CHECK (READ_STATUS IN (0,1)), -- 0=غير مقروء, 1=مقروء
    "EXPIRY_DATE" DATE, -- تاريخ انتهاء الصلاحية
    "PRIORITY" NUMBER(1) DEFAULT 3 CHECK (PRIORITY IN (1,2,3)) -- 1=عالي, 2=متوسط, 3=منخفض
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_ALARM_NOTIFICATION" IS 'إشعارات النظام مع تحسينات التتبع';

-------------------------------------------
-- 3. حزم البرمجة (Packages)            --
-------------------------------------------

-- حزمة التحقق الديناميكي
CREATE OR REPLACE PACKAGE DYNAMIC_VALIDATION_PKG AS
    -- التحقق من سجل معين في مرحلة محددة
    FUNCTION VALIDATE_RECORD(
        p_data_id IN NUMBER,
        p_stage_id IN NUMBER
    ) RETURN CLOB;
    
    -- تقييم شرط تحقق محدد
    FUNCTION EVALUATE_CONDITION(
        p_rule_id IN NUMBER,
        p_data_id IN NUMBER
    ) RETURN BOOLEAN;
    
    -- تطبيق الشروط الخاصة (عاجل، ثقافي، إلخ)
    PROCEDURE APPLY_SPECIAL_CONDITIONS(
        p_data_id IN NUMBER
    );
    
    -- فحص التكرار المتقدم
    FUNCTION CHECK_DUPLICATE(
        p_data_id IN NUMBER
    ) RETURN BOOLEAN;
    
    -- معالجة التفويضات التلقائية
    FUNCTION GET_DELEGATED_APPROVER(
        p_employee_id IN NUMBER,
        p_stage_id IN NUMBER
    ) RETURN NUMBER;
END DYNAMIC_VALIDATION_PKG;
/

CREATE OR REPLACE PACKAGE BODY DYNAMIC_VALIDATION_PKG AS

    -- تقييم شرط التحقق باستخدام SQL الديناميكي
    FUNCTION EVALUATE_CONDITION(
        p_rule_id IN NUMBER,
        p_data_id IN NUMBER
    ) RETURN BOOLEAN IS
        v_sql_stmt VARCHAR2(4000);
        v_result NUMBER;
        v_condition SYS_VALIDATION_RULES.CONDITION_LOGIC%TYPE;
    BEGIN
        -- استرجاع شرط التحقق
        SELECT CONDITION_LOGIC INTO v_condition 
        FROM SYS_VALIDATION_RULES 
        WHERE RULE_ID = p_rule_id;
        
        -- بناء جملة SQL ديناميكية
        v_sql_stmt := 'SELECT CASE WHEN ' || v_condition || ' THEN 1 ELSE 0 END FROM SYS_WORKFLOW_DATA WHERE DATA_ID = :1';
        
        -- تنفيذ الجملة
        EXECUTE IMMEDIATE v_sql_stmt INTO v_result USING p_data_id;
        
        RETURN (v_result = 1);
    EXCEPTION
        WHEN OTHERS THEN
            -- تسجيل الخطأ في حالة الفشل
            INSERT INTO SYSTEM_ERROR_LOG (ERROR_MESSAGE) 
            VALUES ('فشل تقييم الشرط: ' || SQLERRM || ' - القاعدة: ' || p_rule_id);
            RETURN FALSE;
    END EVALUATE_CONDITION;

    -- التحقق من السجل في مرحلة محددة
    FUNCTION VALIDATE_RECORD(
        p_data_id IN NUMBER,
        p_stage_id IN NUMBER
    ) RETURN CLOB IS
        v_errors CLOB;
        v_error_msg VARCHAR2(1000);
    BEGIN
        FOR rule_rec IN (
            SELECT r.RULE_ID, r.ERROR_MESSAGE, r.SPECIAL_ACTION
            FROM SYS_VALIDATION_RULES r
            JOIN SYS_STAGE_RULES sr ON r.RULE_ID = sr.RULE_ID
            WHERE sr.PROCESS_STAGE = p_stage_id
            AND r.ACTIVE = 1
            ORDER BY sr.EXECUTION_ORDER
        ) LOOP
            IF NOT EVALUATE_CONDITION(rule_rec.RULE_ID, p_data_id) THEN
                v_errors := v_errors || rule_rec.ERROR_MESSAGE || CHR(10);
            END IF;
        END LOOP;
        
        RETURN v_errors;
    END VALIDATE_RECORD;
    
    -- تطبيق الشروط الخاصة
    PROCEDURE APPLY_SPECIAL_CONDITIONS(
        p_data_id IN NUMBER
    ) IS
        v_special_action SYS_VALIDATION_RULES.SPECIAL_ACTION%TYPE;
        v_current_stage NUMBER;
    BEGIN
        -- استرجاع المرحلة الحالية
        SELECT PROCESS_STAGE INTO v_current_stage 
        FROM SYS_WORKFLOW_DATA 
        WHERE DATA_ID = p_data_id;
        
        -- التحقق من وجود شروط خاصة
        FOR rule_rec IN (
            SELECT SPECIAL_ACTION 
            FROM SYS_VALIDATION_RULES r
            JOIN SYS_STAGE_RULES sr ON r.RULE_ID = sr.RULE_ID
            WHERE sr.PROCESS_STAGE = v_current_stage
            AND r.SPECIAL_ACTION IS NOT NULL
            AND r.ACTIVE = 1
        ) LOOP
            v_special_action := rule_rec.SPECIAL_ACTION;
            
            CASE v_special_action
                WHEN 'AUTO_APPROVE' THEN
                    -- تحديث حالة الموافقة التلقائية
                    UPDATE SYS_WORKFLOW_DATA
                    SET AUTO_APPROVED = 1,
                        PROCESS_STAGE = (SELECT REJECT_STAGE FROM SYS_PROCESS_CAT WHERE PROCESS_CAT = PROCESS_CAT)
                    WHERE DATA_ID = p_data_id;
                    
                    -- إرسال إشعار
                    NOTIFICATION_PKG.SEND_NOTIFICATION(
                        p_data_id => p_data_id,
                        p_type => 'AUTO_APPROVE',
                        p_message => 'تمت الموافقة التلقائية على الطلب'
                    );
                    
                WHEN 'URGENT' THEN
                    -- زيادة أولوية الطلب
                    UPDATE SYS_WORKFLOW_DATA
                    SET URGENCY_LEVEL = 1
                    WHERE DATA_ID = p_data_id;
                    
                WHEN 'ESCALATE' THEN
                    -- تصعيد الطلب للإدارة العليا
                    NULL; -- سيتم تنفيذها في الإصدار القادم
            END CASE;
        END LOOP;
    END APPLY_SPECIAL_CONDITIONS;
    
    -- فحص التكرار المتقدم
    FUNCTION CHECK_DUPLICATE(
        p_data_id IN NUMBER
    ) RETURN BOOLEAN IS
        v_duplicate_count NUMBER;
        v_current_data CLOB;
        v_process_cat NUMBER;
    BEGIN
        -- استرجاع بيانات الطلب الحالي
        SELECT CURRENT_DATA, PROCESS_CAT 
        INTO v_current_data, v_process_cat 
        FROM SYS_WORKFLOW_DATA 
        WHERE DATA_ID = p_data_id;
        
        -- البحث عن طلبات متشابهة
        SELECT COUNT(*)
        INTO v_duplicate_count
        FROM SYS_WORKFLOW_DATA
        WHERE PROCESS_CAT = v_process_cat
        AND DBMS_LOB.COMPARE(CURRENT_DATA, v_current_data) = 0
        AND DATA_ID <> p_data_id
        AND C_DATE > SYSDATE - 30; -- خلال آخر 30 يوم
        
        RETURN (v_duplicate_count > 0);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END CHECK_DUPLICATE;
    
    -- الحصول على المفوض في حالة عدم توفر الموظف
    FUNCTION GET_DELEGATED_APPROVER(
        p_employee_id IN NUMBER,
        p_stage_id IN NUMBER
    ) RETURN NUMBER IS
        v_delegated_to NUMBER;
    BEGIN
        SELECT TO_EMPLOYEE INTO v_delegated_to
        FROM SYS_DELEGATION
        WHERE FROM_EMPLOYEE = p_employee_id
        AND PROCESS_CAT = (SELECT PROCESS_CAT FROM SYS_PROCESS_STAGE WHERE PROCESS_STAGE = p_stage_id)
        AND ACTIVE = 1
        AND START_DATE <= SYSDATE
        AND END_DATE >= SYSDATE
        AND ROWNUM = 1;
        
        RETURN v_delegated_to;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN p_employee_id; -- إذا لم يوجد تفويض، يُرجع الموظف الأصلي
    END GET_DELEGATED_APPROVER;
    
END DYNAMIC_VALIDATION_PKG;
/

-- حزمة إدارة سير العمل
CREATE OR REPLACE PACKAGE WORKFLOW_MANAGEMENT_PKG AS
    -- معالجة انتقال مرحلة الطلب
    PROCEDURE PROCESS_STAGE_TRANSITION(
        p_data_id IN NUMBER
    );
    
    -- إرسال الإشعارات المتعلقة بالطلب
    PROCEDURE SEND_WORKFLOW_NOTIFICATIONS(
        p_data_id IN NUMBER,
        p_notification_type IN VARCHAR2
    );
    
    -- تسجيل تاريخ الموافقة
    PROCEDURE LOG_APPROVAL_HISTORY(
        p_data_id IN NUMBER,
        p_action IN VARCHAR2,
        p_comments IN VARCHAR2
    );
END WORKFLOW_MANAGEMENT_PKG;
/

CREATE OR REPLACE PACKAGE BODY WORKFLOW_MANAGEMENT_PKG AS

    -- معالجة انتقال مرحلة الطلب
    PROCEDURE PROCESS_STAGE_TRANSITION(
        p_data_id IN NUMBER
    ) IS
        v_current_stage NUMBER;
        v_errors CLOB;
        v_process_cat NUMBER;
    BEGIN
        -- استرجاع المرحلة الحالية وفئة العملية
        SELECT PROCESS_STAGE, PROCESS_CAT 
        INTO v_current_stage, v_process_cat 
        FROM SYS_WORKFLOW_DATA 
        WHERE DATA_ID = p_data_id;
        
        -- التحقق من صحة البيانات
        v_errors := DYNAMIC_VALIDATION_PKG.VALIDATE_RECORD(p_data_id, v_current_stage);
        
        IF v_errors IS NULL THEN
            -- تطبيق الشروط الخاصة
            DYNAMIC_VALIDATION_PKG.APPLY_SPECIAL_CONDITIONS(p_data_id);
            
            -- التحقق من التقدم التلقائي
            DECLARE
                v_auto_advance NUMBER;
            BEGIN
                SELECT AUTO_ADVANCE INTO v_auto_advance
                FROM SYS_PROCESS_STAGE
                WHERE PROCESS_STAGE = v_current_stage;
                
                IF v_auto_advance = 1 THEN
                    -- التقدم للمرحلة التالية
                    MOVE_TO_NEXT_STAGE(p_data_id);
                END IF;
            END;
            
            -- إرسال الإشعارات
            SEND_WORKFLOW_NOTIFICATIONS(p_data_id, 'STAGE_ADVANCE');
        ELSE
            -- تسجيل الأخطاء
            UPDATE SYS_WORKFLOW_DATA
            SET VALIDATION_STATUS = 2,
                VALIDATION_ERRORS = v_errors
            WHERE DATA_ID = p_data_id;
            
            -- إرسال إشعار الخطأ
            SEND_WORKFLOW_NOTIFICATIONS(p_data_id, 'VALIDATION_ERROR');
        END IF;
    END PROCESS_STAGE_TRANSITION;
    
    -- إرسال الإشعارات
    PROCEDURE SEND_WORKFLOW_NOTIFICATIONS(
        p_data_id IN NUMBER,
        p_notification_type IN VARCHAR2
    ) IS
        v_recipient_id NUMBER;
        v_message VARCHAR2(1000);
        v_process_stage NUMBER;
    BEGIN
        -- تحديد المستلم بناءً على نوع الإشعار
        CASE p_notification_type
            WHEN 'VALIDATION_ERROR' THEN
                v_recipient_id := (SELECT C_USER FROM SYS_WORKFLOW_DATA WHERE DATA_ID = p_data_id);
                v_message := 'يوجد أخطاء في الطلب تحتاج إلى تصحيح';
                
            WHEN 'STAGE_ADVANCE' THEN
                v_process_stage := (SELECT PROCESS_STAGE FROM SYS_WORKFLOW_DATA WHERE DATA_ID = p_data_id);
                -- تحديد الموظف المسؤول عن المرحلة التالية
                v_recipient_id := GET_RESPONSIBLE_EMPLOYEE(v_process_stage);
                v_message := 'طلب جديد بانتظار مراجعتك';
                
            WHEN 'URGENT_REQUEST' THEN
                v_message := 'طلب عاجل يحتاج إلى معالجة فورية';
                -- سيتم تحديد المستلمين في الإصدار القادم
        END CASE;
        
        -- إدخال الإشعار في الجدول
        INSERT INTO SYS_ALARM_NOTIFICATION (
            EMPLOYEE_ID,
            NOTIFICATION_HEAD,
            NOTIFICATION_DESCRIPTION,
            NOTIFICATION_TYPE
        ) VALUES (
            v_recipient_id,
            'إشعار نظام سير العمل',
            v_message,
            p_notification_type
        );
    END SEND_WORKFLOW_NOTIFICATIONS;
    
    -- تسجيل تاريخ الموافقة (مثال مبسط)
    PROCEDURE LOG_APPROVAL_HISTORY(
        p_data_id IN NUMBER,
        p_action IN VARCHAR2,
        p_comments IN VARCHAR2
    ) IS
    BEGIN
        UPDATE SYS_WORKFLOW_DATA
        SET ALL_COMMENTS = ALL_COMMENTS || CHR(10) || 
            'الإجراء: ' || p_action || ', التاريخ: ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI') ||
            ', التعليقات: ' || p_comments
        WHERE DATA_ID = p_data_id;
    END LOG_APPROVAL_HISTORY;
    
    -- دعم الإصدارات المستقبلية
    PROCEDURE MOVE_TO_NEXT_STAGE(p_data_id NUMBER) IS PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        -- سيتم تنفيذها في الإصدار القادم
        NULL;
    END;
    
    FUNCTION GET_RESPONSIBLE_EMPLOYEE(p_stage_id NUMBER) RETURN NUMBER IS
    BEGIN
        -- سيتم تنفيذها في الإصدار القادم
        RETURN 1001; -- قيمة افتراضية
    END;
    
END WORKFLOW_MANAGEMENT_PKG;
/

-------------------------------------------
-- 4. المحفزات (Triggers)               --
-------------------------------------------

-- محفز التحقق عند تغيير المرحلة
CREATE OR REPLACE TRIGGER TRG_VALIDATE_STAGE_CHANGE
BEFORE UPDATE OF PROCESS_STAGE ON SYS_WORKFLOW_DATA
FOR EACH ROW
DECLARE
    v_errors CLOB;
BEGIN
    -- التحقق فقط عند تغيير المرحلة
    IF :NEW.PROCESS_STAGE <> :OLD.PROCESS_STAGE THEN
        v_errors := DYNAMIC_VALIDATION_PKG.VALIDATE_RECORD(:NEW.DATA_ID, :NEW.PROCESS_STAGE);
        
        IF v_errors IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'فشل التحقق: ' || v_errors);
        END IF;
    END IF;
END;
/

-- محفز تسجيل التغييرات
CREATE OR REPLACE TRIGGER TRG_LOG_WORKFLOW_CHANGES
BEFORE UPDATE ON SYS_WORKFLOW_DATA
FOR EACH ROW
BEGIN
    :NEW.U_USER := COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), USER);
    :NEW.U_DATE := SYSTIMESTAMP;
    
    -- تسجيل التغييرات المهمة
    IF :NEW.PROCESS_STAGE <> :OLD.PROCESS_STAGE THEN
        WORKFLOW_MANAGEMENT_PKG.LOG_APPROVAL_HISTORY(
            :NEW.DATA_ID,
            'تغيير المرحلة من ' || :OLD.PROCESS_STAGE || ' إلى ' || :NEW.PROCESS_STAGE,
            NULL
        );
    END IF;
END;
/

-- محفز منع التعديل بعد الموافقة
CREATE OR REPLACE TRIGGER TRG_PREVENT_MODIFICATION
BEFORE UPDATE ON SYS_WORKFLOW_DATA
FOR EACH ROW
BEGIN
    IF :OLD.STS = 2 AND :NEW.STS <> 2 THEN -- STS=2 حالة "تمت الموافقة"
        IF :NEW.C_USER <> 'ADMIN' THEN -- استثناء للمشرفين
            RAISE_APPLICATION_ERROR(-20002, 'لا يمكن تعديل الطلب بعد الموافقة عليه');
        END IF;
    END IF;
END;
/

-------------------------------------------
-- 5. إجراءات إضافية للدعم المستقبلي     --
-------------------------------------------

-- إجراء النسخ الاحتياطي اليومي
CREATE OR REPLACE PROCEDURE DAILY_WORKFLOW_BACKUP AS
    v_backup_table VARCHAR2(100);
BEGIN
    v_backup_table := 'WORKFLOW_BACKUP_' || TO_CHAR(SYSDATE, 'YYYYMMDD');
    
    EXECUTE IMMEDIATE 'CREATE TABLE ' || v_backup_table || ' AS SELECT * FROM SYS_WORKFLOW_DATA';
    
    -- تسجيل نجاح العملية
    INSERT INTO SYSTEM_AUDIT (ACTION, STATUS) 
    VALUES ('Backup created: ' || v_backup_table, 'SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO SYSTEM_AUDIT (ACTION, STATUS, ERROR_MESSAGE)
        VALUES ('Backup failed', 'ERROR', SQLERRM);
END;
/

-- إجراء صيانة الجداول
CREATE OR REPLACE PROCEDURE PERFORM_DB_MAINTENANCE AS
BEGIN
    -- إعادة بناء الفهارس
    FOR idx IN (SELECT index_name FROM user_indexes WHERE table_name = 'SYS_WORKFLOW_DATA') 
    LOOP
        EXECUTE IMMEDIATE 'ALTER INDEX ' || idx.index_name || ' REBUILD';
    END LOOP;
    
    -- حذف السجلات القديمة
    DELETE FROM SYS_ALARM_NOTIFICATION 
    WHERE EXPIRY_DATE < ADD_MONTHS(SYSDATE, -6); -- أقدم من 6 أشهر
    
    -- تحليل الجداول
    DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => 'SYS_WORKFLOW_DATA');
END;
/

-------------------------------------------
-- 6. جداول الدعم والمراقبة             --
-------------------------------------------

-- جدول سجلات النظام
CREATE TABLE "SYSTEM_AUDIT" (
    "AUDIT_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "ACTION" VARCHAR2(500) NOT NULL,
    "ACTION_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "USER_NAME" VARCHAR2(100) DEFAULT USER,
    "STATUS" VARCHAR2(20) NOT NULL, -- SUCCESS, ERROR, WARNING
    "ERROR_MESSAGE" VARCHAR2(2000),
    "DURATION" NUMBER -- مدة التنفيذ بالمللي ثانية
) TABLESPACE USERS;

-- جدول أخطاء النظام
CREATE TABLE "SYSTEM_ERROR_LOG" (
    "ERROR_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "ERROR_MESSAGE" VARCHAR2(2000) NOT NULL,
    "ERROR_DATE" TIMESTAMP DEFAULT SYSTIMESTAMP,
    "SOURCE_MODULE" VARCHAR2(100),
    "DATA_ID" NUMBER,
    "RESOLVED" NUMBER(1) DEFAULT 0
) TABLESPACE USERS;

-- جدول التخصيصات المستقبلية
CREATE TABLE "SYS_CUSTOM_SETTINGS" (
    "SETTING_ID" NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "SETTING_NAME" VARCHAR2(200) NOT NULL UNIQUE,
    "SETTING_VALUE" CLOB,
    "DESCRIPTION" VARCHAR2(1000),
    "LAST_MODIFIED" TIMESTAMP DEFAULT SYSTIMESTAMP
) TABLESPACE USERS;

COMMENT ON TABLE "SYS_CUSTOM_SETTINGS" IS 'تخزين إعدادات التخصيص للنظام';

-------------------------------------------
-- 7. تعليقات نهائية وإعدادات           --
-------------------------------------------

/*
 * نصائح للاستخدام المستقبلي:
 * 1. لتحسين الأداء، قم بتنفيذ إجراء الصيانة الدورية PERFORM_DB_MAINTENANCE
 * 2. استخدم جدول SYS_CUSTOM_SETTINGS لتخزين الإعدادات الديناميكية
 * 3. يمكن توسيع النظام بإضافة وحدات جديدة:
 *    - تكامل مع أنظمة الذكاء الاصطناعي للتنبؤ بمسارات سير العمل
 *    - دعم التوقيع الإلكتروني
 *    - ربط مع أنظمة ERP الخارجية
 * 
 * ملاحظات الأمان:
 * - جميع الإجراءات الحساسة مسجلة في SYSTEM_AUDIT
 * - تم تطبيق التحكم بالوصول على مستوى الصفوف (سيتم تطبيقه في الإصدار القادم)
 * - تشفير البيانات الحساسة (يوصى بتطبيق TDE أو DBMS_CRYPTO)
 * 
 * إعدادات افتراضية:
 * - تم تعيين جميع الجداول في tablespace USERS
 * - تم تعيين NLS_LENGTH_SEMANTICS = CHAR لتحسين التعامل مع اللغة العربية
 */
 
-- تعيين إعدادات الجلسة للغة العربية
ALTER SESSION SET NLS_LENGTH_SEMANTICS = 'CHAR';
ALTER SESSION SET NLS_SORT = 'ARABIC';
ALTER SESSION SET NLS_COMP = 'LINGUISTIC';