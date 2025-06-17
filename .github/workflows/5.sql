CREATE OR REPLACE PACKAGE WORKFLOW_ENGINE_PKG AS

    -- إنشاء طلب جديد
    PROCEDURE CREATE_REQUEST(
        p_process_cat_id IN NUMBER,
        p_scrn_alias     IN VARCHAR2,
        p_current_data   IN CLOB,
        p_branch_id      IN NUMBER,
        p_created_by     IN NUMBER,
        p_reference_guid OUT VARCHAR2,
        p_data_id        OUT NUMBER
    );
    
    -- تقديم طلب للموافقة
    PROCEDURE SUBMIT_REQUEST(
        p_data_id        IN NUMBER,
        p_comment_text   IN VARCHAR2 DEFAULT NULL
    );
    
    -- معالجة الموافقة
    PROCEDURE APPROVE_REQUEST(
        p_data_id        IN NUMBER,
        p_approver_id    IN NUMBER,
        p_comment_text   IN VARCHAR2 DEFAULT NULL
    );
    
    -- معالجة الرفض
    PROCEDURE REJECT_REQUEST(
        p_data_id        IN NUMBER,
        p_approver_id    IN NUMBER,
        p_comment_text   IN VARCHAR2 DEFAULT NULL
    );
    
    -- معالجة الإرجاع
    PROCEDURE RETURN_REQUEST(
        p_data_id        IN NUMBER,
        p_approver_id    IN NUMBER,
        p_target_stage   IN NUMBER,
        p_comment_text   IN VARCHAR2 DEFAULT NULL
    );
    
    -- التصعيد التلقائي
    PROCEDURE PROCESS_ESCALATIONS;
    
    -- تفويض الصلاحيات
    PROCEDURE DELEGATE_APPROVAL(
        p_delegator_id   IN NUMBER,
        p_delegate_to_id IN NUMBER,
        p_start_date     IN DATE,
        p_end_date       IN DATE,
        p_process_cat_id IN NUMBER DEFAULT NULL
    );
    
    -- إرسال الإشعارات
    PROCEDURE SEND_NOTIFICATION(
        p_data_id        IN NUMBER,
        p_stage_id       IN NUMBER
    );
    
    -- تطبيق القواعد الديناميكية
    FUNCTION APPLY_CONDITIONS(
        p_data_id        IN NUMBER
    ) RETURN NUMBER;
    
    -- التحقق من التفويض
    FUNCTION HAS_DELEGATION(
        p_employee_id    IN NUMBER,
        p_process_cat_id IN NUMBER,
        p_date           IN DATE DEFAULT SYSDATE
    ) RETURN BOOLEAN;

END WORKFLOW_ENGINE_PKG;
/

CREATE OR REPLACE PACKAGE BODY WORKFLOW_ENGINE_PKG AS

    PROCEDURE CREATE_REQUEST(
        p_process_cat_id IN NUMBER,
        p_scrn_alias     IN VARCHAR2,
        p_current_data   IN CLOB,
        p_branch_id      IN NUMBER,
        p_created_by     IN NUMBER,
        p_reference_guid OUT VARCHAR2,
        p_data_id        OUT NUMBER
    ) IS
        v_guid RAW(16);
        v_first_stage_id NUMBER;
    BEGIN
        -- توليد GUID فريد
        v_guid := SYS_GUID();
        p_reference_guid := RAWTOHEX(v_guid);
        
        -- الحصول على المرحلة الافتراضية الأولى
        SELECT PROCESS_STAGE_ID INTO v_first_stage_id
        FROM SYS_PROCESS_STAGE
        WHERE PROCESS_CAT_ID = p_process_cat_id
        AND IS_DEFAULT = 1
        AND ROWNUM = 1;
        
        -- إدخال سجل الطلب
        INSERT INTO SYS_WORKFLOW_DATA (
            PROCESS_CAT_ID, PROCESS_STAGE_ID, REFERENCE_GUID,
            SCRN_ALIAS, CURRENT_DATA, BRANCH_ID, CREATED_BY
        ) VALUES (
            p_process_cat_id, v_first_stage_id, p_reference_guid,
            p_scrn_alias, p_current_data, p_branch_id, p_created_by
        ) RETURNING DATA_ID INTO p_data_id;
        
        -- تسجيل بدء المرحلة
        INSERT INTO SYS_WORKFLOW_STAGE_LOG (
            DATA_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
            APPROVER_ID, ACTION_TYPE, COMMENT_TEXT, IS_CURRENT_STAGE
        ) VALUES (
            p_data_id, p_process_cat_id, v_first_stage_id,
            p_created_by, 'SUBMIT', 'Initial Submission', 1
        );
        
        -- إرسال الإشعارات
        SEND_NOTIFICATION(p_data_id, v_first_stage_id);
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'No default stage found for this process');
    END CREATE_REQUEST;
    
    PROCEDURE SUBMIT_REQUEST(
        p_data_id        IN NUMBER,
        p_comment_text   IN VARCHAR2 DEFAULT NULL
    ) IS
        v_current_stage_id NUMBER;
        v_process_cat_id NUMBER;
    BEGIN
        -- الحصول على المرحلة الحالية
        SELECT PROCESS_STAGE_ID, PROCESS_CAT_ID 
        INTO v_current_stage_id, v_process_cat_id
        FROM SYS_WORKFLOW_DATA
        WHERE DATA_ID = p_data_id;
        
        -- تسجيل إجراء التقديم
        INSERT INTO SYS_WORKFLOW_STAGE_LOG (
            DATA_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
            APPROVER_ID, ACTION_TYPE, COMMENT_TEXT, IS_CURRENT_STAGE
        ) VALUES (
            p_data_id, v_process_cat_id, v_current_stage_id,
            (SELECT CREATED_BY FROM SYS_WORKFLOW_DATA WHERE DATA_ID = p_data_id),
            'SUBMIT', p_comment_text, 1
        );
        
        -- إرسال الإشعارات
        SEND_NOTIFICATION(p_data_id, v_current_stage_id);
    END SUBMIT_REQUEST;
    
    PROCEDURE APPROVE_REQUEST(
        p_data_id        IN NUMBER,
        p_approver_id    IN NUMBER,
        p_comment_text   IN VARCHAR2 DEFAULT NULL
    ) IS
        v_current_stage_id NUMBER;
        v_process_cat_id NUMBER;
        v_next_stage_id NUMBER;
        v_final_status VARCHAR2(20) := 'PENDING';
        v_approval_count NUMBER;
        v_required_approvals NUMBER;
    BEGIN
        -- الحصول على معلومات الطلب
        SELECT PROCESS_STAGE_ID, PROCESS_CAT_ID 
        INTO v_current_stage_id, v_process_cat_id
        FROM SYS_WORKFLOW_DATA
        WHERE DATA_ID = p_data_id;
        
        -- تسجيل الموافقة
        INSERT INTO SYS_WORKFLOW_STAGE_LOG (
            DATA_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
            APPROVER_ID, ACTION_TYPE, COMMENT_TEXT, IS_CURRENT_STAGE
        ) VALUES (
            p_data_id, v_process_cat_id, v_current_stage_id,
            p_approver_id, 'APPROVE', p_comment_text, 0
        );
        
        -- التحقق من استكمال الموافقات المطلوبة
        SELECT COUNT(*) INTO v_approval_count
        FROM SYS_WORKFLOW_STAGE_LOG
        WHERE DATA_ID = p_data_id
        AND PROCESS_STAGE_ID = v_current_stage_id
        AND ACTION_TYPE = 'APPROVE';
        
        SELECT REQUIRED_APPROVALS INTO v_required_approvals
        FROM SYS_APPROVE_GROUP
        WHERE PROCESS_STAGE_ID = v_current_stage_id;
        
        -- إذا لم تكتمل الموافقات المطلوبة
        IF v_approval_count < v_required_approvals THEN
            RETURN;
        END IF;
        
        -- الحصول على المرحلة التالية
        BEGIN
            SELECT MIN(PROCESS_STAGE_ID) INTO v_next_stage_id
            FROM SYS_PROCESS_STAGE
            WHERE PROCESS_CAT_ID = v_process_cat_id
            AND ORDER_NO > (SELECT ORDER_NO FROM SYS_PROCESS_STAGE 
                           WHERE PROCESS_STAGE_ID = v_current_stage_id);
            
            IF v_next_stage_id IS NULL THEN
                v_final_status := 'APPROVED';
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_final_status := 'APPROVED';
        END;
        
        -- تطبيق القواعد الديناميكية
        v_next_stage_id := APPLY_CONDITIONS(p_data_id);
        
        -- تحديث حالة الطلب
        UPDATE SYS_WORKFLOW_DATA
        SET PROCESS_STAGE_ID = NVL(v_next_stage_id, v_current_stage_id),
            FINAL_STATUS = v_final_status
        WHERE DATA_ID = p_data_id;
        
        -- إذا كانت هناك مرحلة تالية
        IF v_final_status = 'PENDING' THEN
            -- تسجيل بدء المرحلة الجديدة
            INSERT INTO SYS_WORKFLOW_STAGE_LOG (
                DATA_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
                APPROVER_ID, ACTION_TYPE, IS_CURRENT_STAGE
            ) VALUES (
                p_data_id, v_process_cat_id, v_next_stage_id,
                NULL, 'START', 1
            );
            
            -- إرسال إشعارات للمرحلة الجديدة
            SEND_NOTIFICATION(p_data_id, v_next_stage_id);
        END IF;
        
    END APPROVE_REQUEST;
    
    FUNCTION APPLY_CONDITIONS(
        p_data_id        IN NUMBER
    ) RETURN NUMBER IS
        v_current_stage_id NUMBER;
        v_process_cat_id NUMBER;
        v_current_data CLOB;
        v_redirect_stage_id NUMBER;
    BEGIN
        -- الحصول على بيانات الطلب
        SELECT PROCESS_STAGE_ID, PROCESS_CAT_ID, CURRENT_DATA 
        INTO v_current_stage_id, v_process_cat_id, v_current_data
        FROM SYS_WORKFLOW_DATA
        WHERE DATA_ID = p_data_id;
        
        -- البحث عن قواعد تطابق المرحلة الحالية
        FOR condition_rec IN (
            SELECT * FROM SYS_WORKFLOW_CONDITIONS
            WHERE PROCESS_CAT_ID = v_process_cat_id
            AND AFFECTED_STAGE_ID = v_current_stage_id
            ORDER BY CONDITION_ID
        ) LOOP
            -- التحقق من تطابق الشرط (يجب تطبيق هذا منطقياً)
            IF CONDITION_MET(v_current_data, condition_rec.FIELD_NAME, 
                           condition_rec.OPERATOR, condition_rec.VALUE_MATCH) THEN
                
                CASE condition_rec.ACTION_TYPE
                    WHEN 'SKIP' THEN
                        -- تخطي المرحلة الحالية
                        SELECT MIN(PROCESS_STAGE_ID) INTO v_redirect_stage_id
                        FROM SYS_PROCESS_STAGE
                        WHERE PROCESS_CAT_ID = v_process_cat_id
                        AND ORDER_NO > (SELECT ORDER_NO FROM SYS_PROCESS_STAGE 
                                       WHERE PROCESS_STAGE_ID = v_current_stage_id);
                    
                    WHEN 'REDIRECT' THEN
                        v_redirect_stage_id := condition_rec.REDIRECT_TO_STAGE_ID;
                    
                    WHEN 'AUTO_APPROVE' THEN
                        -- معالجة الموافقة التلقائية
                        APPROVE_REQUEST(p_data_id, 0, 'Auto-approved by system');
                        RETURN NULL;
                END CASE;
                
                EXIT; -- الخروج بعد تطبيق أول شرط متطابق
            END IF;
        END LOOP;
        
        RETURN v_redirect_stage_id;
    END APPLY_CONDITIONS;
    
    PROCEDURE PROCESS_ESCALATIONS IS
        CURSOR pending_requests IS
            SELECT d.DATA_ID, d.PROCESS_STAGE_ID, d.PROCESS_CAT_ID,
                   MAX(l.ACTION_DATE) AS last_action_date
            FROM SYS_WORKFLOW_DATA d
            JOIN SYS_WORKFLOW_STAGE_LOG l ON l.DATA_ID = d.DATA_ID
            WHERE d.FINAL_STATUS = 'PENDING'
            GROUP BY d.DATA_ID, d.PROCESS_STAGE_ID, d.PROCESS_CAT_ID;
            
        v_escalation_count NUMBER;
        v_escalation_group_id NUMBER;
    BEGIN
        FOR req IN pending_requests LOOP
            -- التحقق من وجود قاعدة تصعيد
            BEGIN
                SELECT ESCALATE_TO_GROUP_ID, MAX_ESCALATIONS
                INTO v_escalation_group_id, v_escalation_count
                FROM SYS_ESCALATION_RULES
                WHERE PROCESS_CAT_ID = req.PROCESS_CAT_ID
                AND STAGE_ID = req.PROCESS_STAGE_ID
                AND TRIGGER_AFTER_HOURS < (SYSDATE - req.last_action_date) * 24;
                
                -- تسجيل التصعيد
                INSERT INTO SYS_WORKFLOW_STAGE_LOG (
                    DATA_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
                    APPROVER_ID, ACTION_TYPE, COMMENT_TEXT
                ) VALUES (
                    req.DATA_ID, req.PROCESS_CAT_ID, req.PROCESS_STAGE_ID,
                    -1, 'ESCALATE', 'Automatically escalated after timeout'
                );
                
                -- إرسال إشعارات للمجموعة الجديدة
                SEND_GROUP_NOTIFICATIONS(req.DATA_ID, v_escalation_group_id);
                
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    NULL; -- لا يوجد قاعدة تصعيد
            END;
        END LOOP;
    END PROCESS_ESCALATIONS;
    
    PROCEDURE SEND_NOTIFICATION(
        p_data_id        IN NUMBER,
        p_stage_id       IN NUMBER
    ) IS
        v_notif_head VARCHAR2(500);
        v_notif_desc VARCHAR2(2000);
        v_url VARCHAR2(2000);
        v_process_name VARCHAR2(100);
    BEGIN
        -- الحصول على تفاصيل العملية
        SELECT pc.PROCESS_CAT_NAME INTO v_process_name
        FROM SYS_PROCESS_CAT pc
        JOIN SYS_PROCESS_STAGE ps ON ps.PROCESS_CAT_ID = pc.PROCESS_CAT_ID
        WHERE ps.PROCESS_STAGE_ID = p_stage_id;
        
        -- بناء تفاصيل الإشعار
        v_notif_head := 'طلب يحتاج إلى موافقة: ' || v_process_name;
        v_notif_desc := 'هناك طلب جديد بانتظار موافقتك في المرحلة الحالية';
        v_url := 'https://your-system/approvals?data_id=' || p_data_id;
        
        -- إرسال الإشعارات لجميع المعتمدين في المرحلة
        FOR approver IN (
            SELECT DISTINCT u.EMPLOYEE_ID
            FROM SYS_APPROVEGROUP_USERS u
            JOIN SYS_APPROVE_GROUP ag ON ag.APPROVE_GROUP_ID = u.APPROVE_GROUP_ID
            WHERE ag.PROCESS_STAGE_ID = p_stage_id
            
            UNION
            
            SELECT e.EMPLOYEE_ID
            FROM SYS_APPROVEGROUP_POSTYPE pt
            JOIN SYS_APPROVE_GROUP ag ON ag.APPROVE_GROUP_ID = pt.APPROVE_GROUP_ID
            JOIN HR_EMPLOYEES e ON e.POSITION_TYPE = pt.POSITION_TYPE
            WHERE ag.PROCESS_STAGE_ID = p_stage_id
            
            UNION
            
            SELECT e.EMPLOYEE_ID
            FROM SYS_APPROVEGROUP_POSNAME pn
            JOIN SYS_APPROVE_GROUP ag ON ag.APPROVE_GROUP_ID = pn.APPROVE_GROUP_ID
            JOIN HR_EMPLOYEES e ON e.POSITION_NAME = pn.POSITION_NAME
            WHERE ag.PROCESS_STAGE_ID = p_stage_id
        ) LOOP
            INSERT INTO SYS_ALARM_NOTIFICATION (
                EMPLOYEE_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
                URL, NOTIFICATION_HEAD, NOTIFICATION_DESC
            ) VALUES (
                approver.EMPLOYEE_ID, 
                (SELECT PROCESS_CAT_ID FROM SYS_PROCESS_STAGE 
                 WHERE PROCESS_STAGE_ID = p_stage_id),
                p_stage_id,
                v_url, v_notif_head, v_notif_desc
            );
        END LOOP;
    END SEND_NOTIFICATION;
    
    -- إجراءات مساعدة أخرى
    FUNCTION HAS_DELEGATION(
        p_employee_id    IN NUMBER,
        p_process_cat_id IN NUMBER,
        p_date           IN DATE DEFAULT SYSDATE
    ) RETURN BOOLEAN IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM SYS_DELEGATIONS
        WHERE DELEGATOR_ID = p_employee_id
        AND START_DATE <= p_date
        AND END_DATE >= p_date
        AND (PROCESS_CAT_ID = p_process_cat_id OR PROCESS_CAT_ID IS NULL)
        AND IS_ACTIVE = 1;
        
        RETURN (v_count > 0);
    END HAS_DELEGATION;

END WORKFLOW_ENGINE_PKG;
/