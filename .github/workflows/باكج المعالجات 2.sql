CREATE OR REPLACE PACKAGE BODY DYNAMIC_WORKFLOW_PKG AS

    ------------------------------------------------------------
    -- بدء عملية سير عمل جديدة
    ------------------------------------------------------------
    PROCEDURE START_WORKFLOW(
        p_process_cat      IN NUMBER,
        p_process_stage    IN NUMBER,
        p_reference_guid   IN VARCHAR2,
        p_initiator        IN VARCHAR2,
        p_tbl_name         IN VARCHAR2,
        p_page_no          IN NUMBER,
        p_branch_id        IN NUMBER,
        p_data_id          OUT NUMBER
    ) IS
        v_initial_data CLOB;
    BEGIN
        -- الحصول على البيانات الأولية من الجدول المرجعي
        SELECT JSON_OBJECT(*) INTO v_initial_data
        FROM &p_tbl_name
        WHERE GUID = p_reference_guid;
        
        -- إدخال سجل جديد في سير العمل
        INSERT INTO SYS_WORKFLOW_DATA (
            PROCESS_CAT, PROCESS_STAGE, REFERENCE_GUID, 
            CURRENT_DATA, TBL, PAGE_NO, BRANCH_ID,
            C_USER, STATUS
        ) VALUES (
            p_process_cat, p_process_stage, p_reference_guid,
            v_initial_data, p_tbl_name, p_page_no, p_branch_id,
            p_initiator, 'PENDING'
        ) RETURNING DATA_ID INTO p_data_id;
        
        -- إرسال الإشعارات الأولية
        SEND_NOTIFICATION(p_data_id, 'START', 'بدأت عملية سير عمل جديدة');
        
        -- تسجيل العملية في التدقيق
        INSERT INTO SYS_OPERATIONS (...) VALUES (...);
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20001, 'خطأ في بدء سير العمل: ' || SQLERRM);
    END START_WORKFLOW;

    ------------------------------------------------------------
    -- الموافقة على مرحلة
    ------------------------------------------------------------
    PROCEDURE APPROVE_STAGE(
        p_data_id          IN NUMBER,
        p_approver         IN VARCHAR2,
        p_comments         IN CLOB DEFAULT NULL
    ) IS
        v_current_stage NUMBER;
        v_process_cat   NUMBER;
        v_next_stage    NUMBER;
    BEGIN
        -- الحصول على المرحلة الحالية والفئة
        SELECT PROCESS_STAGE, PROCESS_CAT 
        INTO v_current_stage, v_process_cat
        FROM SYS_WORKFLOW_DATA
        WHERE DATA_ID = p_data_id;
        
        -- الحصول على المرحلة التالية
        SELECT MIN(PROCESS_STAGE)
        INTO v_next_stage
        FROM SYS_PROCESS_STAGE
        WHERE PROCESS_CAT = v_process_cat
          AND PROCESS_STAGE > v_current_stage;
        
        -- إذا لم توجد مرحلة تالية، العملية مكتملة
        IF v_next_stage IS NULL THEN
            UPDATE SYS_WORKFLOW_DATA
            SET STATUS = 'COMPLETED',
                U_USER = p_approver,
                U_DATE = SYSTIMESTAMP
            WHERE DATA_ID = p_data_id;
        ELSE
            -- الانتقال للمرحلة التالية
            UPDATE SYS_WORKFLOW_DATA
            SET PROCESS_STAGE = v_next_stage,
                STATUS = 'PENDING',
                U_USER = p_approver,
                U_DATE = SYSTIMESTAMP
            WHERE DATA_ID = p_data_id;
            
            -- إرسال إشعارات للمرحلة الجديدة
            SEND_NOTIFICATION(p_data_id, 'STAGE_CHANGE', 'تمت الموافقة والانتقال لمرحلة جديدة');
        END IF;
        
        -- تسجيل التعليق إذا وجد
        IF p_comments IS NOT NULL THEN
            ADD_COMMENT(p_data_id, p_approver, p_comments);
        END IF;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END APPROVE_STAGE;

    ------------------------------------------------------------
    -- إرسال إشعار
    ------------------------------------------------------------
    PROCEDURE SEND_NOTIFICATION(
        p_data_id          IN NUMBER,
        p_notification_type IN VARCHAR2,
        p_message          IN VARCHAR2
    ) IS
        v_process_cat   NUMBER;
        v_process_stage NUMBER;
        v_ref_guid      VARCHAR2(50);
    BEGIN
        -- الحصول على معلومات العملية
        SELECT PROCESS_CAT, PROCESS_STAGE, REFERENCE_GUID
        INTO v_process_cat, v_process_stage, v_ref_guid
        FROM SYS_WORKFLOW_DATA
        WHERE DATA_ID = p_data_id;
        
        -- إرسال إشعارات للمجموعات المعنية
        FOR group_rec IN (
            SELECT ag.APPROVE_GROUP_ID
            FROM SYS_APPROVE_GROUP ag
            WHERE ag.PROCESS_CAT = v_process_cat
              AND ag.PROCESS_STAGE = v_process_stage
        ) LOOP
            -- إرسال إشعار لكل عضو في المجموعة
            FOR approver_rec IN (
                SELECT emp.EMPLOYEE_ID, emp.EMAIL
                FROM SYS_APPROVEGROUP_POSNAME apn
                JOIN EMPLOYEES emp ON emp.POSITION_NAME = apn.POSITION_NAME
                WHERE apn.APPROVE_GROUP_ID = group_rec.APPROVE_GROUP_ID
            ) LOOP
                INSERT INTO SYS_ALARM_NOTIFCATION (
                    PROCESS_CAT, PROCESS_STAGE, EMPLOYEE_ID,
                    NOTIFICATION_HEAD, NOTIFCATION_DESCRIPTION,
                    ACTION_DATE, NOTIFICATION_TYPE
                ) VALUES (
                    v_process_cat, v_process_stage, approver_rec.EMPLOYEE_ID,
                    'إشعار نظام سير العمل', p_message,
                    SYSTIMESTAMP, p_notification_type
                );
                
                -- هنا يمكن تفعيل إرسال إيميل أو رسالة
                -- APEX_MAIL.SEND(...);
            END LOOP;
        END LOOP;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END SEND_NOTIFICATION;

    ------------------------------------------------------------
    -- التصعيد التلقائي للمراحل المتأخرة (تعمل كـ JOB)
    ------------------------------------------------------------
    PROCEDURE AUTO_ESCALATE IS
    BEGIN
        FOR overdue_rec IN (
            SELECT wd.DATA_ID, wd.PROCESS_STAGE, 
                   ps.ESCALATION_STAGE, wd.C_USER
            FROM SYS_WORKFLOW_DATA wd
            JOIN SYS_PROCESS_STAGE ps ON ps.PROCESS_STAGE = wd.PROCESS_STAGE
            WHERE wd.STATUS = 'PENDING'
              AND wd.C_DATE < SYSTIMESTAMP - ps.TIME_LIMIT
        ) LOOP
            -- تحديث المرحلة إلى مرحلة التصعيد
            UPDATE SYS_WORKFLOW_DATA
            SET PROCESS_STAGE = overdue_rec.ESCALATION_STAGE,
                U_USER = 'AUTO_ESCALATE',
                U_DATE = SYSTIMESTAMP
            WHERE DATA_ID = overdue_rec.DATA_ID;
            
            -- إرسال إشعار التصعيد
            SEND_NOTIFICATION(
                overdue_rec.DATA_ID, 
                'ESCALATION', 
                'تم تصعيد العملية بسبب التأخير'
            );
            
            -- تسجيل في سجل التصعيد
            INSERT INTO SYS_ESCALATION_HISTORY (...) VALUES (...);
        END LOOP;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            -- يمكن تسجيل الخطأ دون إيقاف العملية
    END AUTO_ESCALATE;

    -- باقي الإجراءات تنفذ بنفس المنطق

END DYNAMIC_WORKFLOW_PKG;
/