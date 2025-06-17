-------------------------------------------
-- وظائف مساعدة
-------------------------------------------

-- التحقق من صلاحية الموافقة
CREATE OR REPLACE FUNCTION CAN_APPROVE_REQUEST(
    p_data_id      IN NUMBER,
    p_employee_id  IN NUMBER
) RETURN BOOLEAN IS
    v_is_approver BOOLEAN := FALSE;
    v_process_cat_id NUMBER;
BEGIN
    -- الحصول على معرف العملية
    SELECT PROCESS_CAT_ID INTO v_process_cat_id
    FROM SYS_WORKFLOW_DATA
    WHERE DATA_ID = p_data_id;
    
    -- التحقق من وجود تفويض
    IF WORKFLOW_ENGINE_PKG.HAS_DELEGATION(p_employee_id, v_process_cat_id) THEN
        RETURN TRUE;
    END IF;
    
    -- التحقق من أن المستخدم معتمد
    SELECT CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END INTO v_is_approver
    FROM (
        SELECT 1 FROM SYS_APPROVEGROUP_USERS u
        JOIN SYS_APPROVE_GROUP ag ON ag.APPROVE_GROUP_ID = u.APPROVE_GROUP_ID
        JOIN SYS_WORKFLOW_DATA d ON d.PROCESS_STAGE_ID = ag.PROCESS_STAGE_ID
        WHERE d.DATA_ID = p_data_id AND u.EMPLOYEE_ID = p_employee_id
        
        UNION
        
        SELECT 1 FROM SYS_APPROVEGROUP_POSTYPE pt
        JOIN SYS_APPROVE_GROUP ag ON ag.APPROVE_GROUP_ID = pt.APPROVE_GROUP_ID
        JOIN SYS_WORKFLOW_DATA d ON d.PROCESS_STAGE_ID = ag.PROCESS_STAGE_ID
        JOIN HR_EMPLOYEES e ON e.EMPLOYEE_ID = p_employee_id 
        WHERE d.DATA_ID = p_data_id AND e.POSITION_TYPE = pt.POSITION_TYPE
        
        UNION
        
        SELECT 1 FROM SYS_APPROVEGROUP_POSNAME pn
        JOIN SYS_APPROVE_GROUP ag ON ag.APPROVE_GROUP_ID = pn.APPROVE_GROUP_ID
        JOIN SYS_WORKFLOW_DATA d ON d.PROCESS_STAGE_ID = ag.PROCESS_STAGE_ID
        JOIN HR_EMPLOYEES e ON e.EMPLOYEE_ID = p_employee_id 
        WHERE d.DATA_ID = p_data_id AND e.POSITION_NAME = pn.POSITION_NAME
    );
    
    RETURN v_is_approver;
END;
/

-------------------------------------------
-- أحداث مجدولة
-------------------------------------------

-- جدولة التصعيد التلقائي (تشغيل كل ساعة)
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'AUTO_ESCALATION_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN WORKFLOW_ENGINE_PKG.PROCESS_ESCALATIONS; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=HOURLY; INTERVAL=1',
        enabled         => TRUE
    );
END;
/

-- جدولة التذكير بالإشعارات (تشغيل يومي)
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'NOTIFICATION_REMINDER_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN NOTIFICATION_MGR_PKG.SCHEDULE_REMINDERS; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY; BYHOUR=9',
        enabled         => TRUE
    );
END;
/