CREATE OR REPLACE PACKAGE PKG_WORKFLOW_UTILS AS
    -- التحقق من صلاحية المستخدم للموافقة
    FUNCTION is_user_approver(
        p_user_id      IN VARCHAR2,
        p_workflow_id  IN NUMBER
    ) RETURN BOOLEAN;
    
    -- الحصول على قائمة المعتمدين الحاليين
    FUNCTION get_current_approvers(p_workflow_id IN NUMBER) RETURN SYS_REFCURSOR;
    
    -- الحصول على بيانات الطلب كـ JSON
    FUNCTION get_request_json(p_workflow_id IN NUMBER) RETURN CLOB;
    
    -- التحقق إذا كانت المرحلة النهائية
    FUNCTION is_final_stage(p_stage_id IN NUMBER) RETURN BOOLEAN;
    
    -- التحقق من وجود مرحلة تالية
    FUNCTION has_next_stage(p_workflow_id IN NUMBER) RETURN BOOLEAN;
    
    -- الحصول على معلومات المرحلة
    FUNCTION get_stage_info(p_stage_id IN NUMBER) RETURN VARCHAR2;
    
    -- التحقق من إمكانية التخطي التلقائي
    FUNCTION can_auto_approve(p_workflow_id IN NUMBER) RETURN BOOLEAN;
    
END PKG_WORKFLOW_UTILS;
/

CREATE OR REPLACE PACKAGE BODY PKG_WORKFLOW_UTILS AS

    FUNCTION is_user_approver(
        p_user_id      IN VARCHAR2,
        p_workflow_id  IN NUMBER
    ) RETURN BOOLEAN IS
        v_stage_id     NUMBER;
        v_approver_type VARCHAR2(20);
        v_approver_ref VARCHAR2(500);
        v_count        NUMBER := 0;
    BEGIN
        -- الحصول على المرحلة الحالية
        SELECT current_stage INTO v_stage_id
        FROM sys_workflow_data
        WHERE workflow_id = p_workflow_id;
        
        -- الحصول على إعدادات المعتمدين
        SELECT approver_type, approver_ref 
        INTO v_approver_type, v_approver_ref
        FROM sys_process_stage
        WHERE stage_id = v_stage_id;
        
        -- بناءً على نوع المعتمدين
        CASE v_approver_type
            WHEN 'GROUP' THEN
                SELECT COUNT(*) INTO v_count
                FROM sys_group_members m
                WHERE m.group_id = (
                    SELECT group_id 
                    FROM sys_approve_group 
                    WHERE group_name = v_approver_ref
                )
                AND m.user_id = p_user_id
                AND (m.end_date IS NULL OR m.end_date >= SYSDATE);
                
            WHEN 'ROLE' THEN
                -- التحقق من دور المستخدم في APEX
                SELECT COUNT(*) INTO v_count
                FROM apex_workspace_acl_users
                WHERE user_name = p_user_id
                AND role_names LIKE '%' || v_approver_ref || '%';
                
            WHEN 'QUERY' THEN
                EXECUTE IMMEDIATE 
                    'SELECT COUNT(*) FROM (' || v_approver_ref || ') WHERE user_id = :1' 
                INTO v_count 
                USING p_user_id;
                
        END CASE;
        
        RETURN (v_count > 0);
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END is_user_approver;
    
    -- إجراءات أخرى سيتم تنفيذها بنفس النمط
    
END PKG_WORKFLOW_UTILS;
/