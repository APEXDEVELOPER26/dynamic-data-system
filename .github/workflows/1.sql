CREATE OR REPLACE PACKAGE PKG_WORKFLOW_ENGINE AS
    -- بدء سير عمل جديد
    PROCEDURE start_workflow(
        p_screen_alias   IN VARCHAR2,
        p_reference_id   IN VARCHAR2,
        p_user_id        IN VARCHAR2,
        p_screen_data    IN CLOB DEFAULT NULL
    );
    
    -- تنفيذ عملية الموافقة
    PROCEDURE approve_action(
        p_workflow_id    IN NUMBER,
        p_user_id        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL
    );
    
    -- تنفيذ عملية الرفض
    PROCEDURE reject_action(
        p_workflow_id    IN NUMBER,
        p_user_id        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL,
        p_target_stage   IN NUMBER DEFAULT NULL
    );
    
    -- تفويض الموافقة
    PROCEDURE delegate_approval(
        p_workflow_id    IN NUMBER,
        p_from_user      IN VARCHAR2,
        p_to_user        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL
    );
    
    -- الانتقال للمرحلة التالية
    PROCEDURE advance_stage(
        p_workflow_id    IN NUMBER
    );
    
    -- العودة للمرحلة السابقة
    PROCEDURE rollback_stage(
        p_workflow_id    IN NUMBER,
        p_target_stage   IN NUMBER DEFAULT NULL
    );
    
    -- الحصول على المرحلة الحالية
    FUNCTION get_current_stage(p_workflow_id IN NUMBER) RETURN VARCHAR2;
    
    -- التحقق من وجود مرحلة تالية
    FUNCTION has_next_stage(p_workflow_id IN NUMBER) RETURN BOOLEAN;
    
    -- إلغاء سير العمل
    PROCEDURE cancel_workflow(
        p_workflow_id    IN NUMBER,
        p_user_id        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL
    );
    
END PKG_WORKFLOW_ENGINE;
/

CREATE OR REPLACE PACKAGE BODY PKG_WORKFLOW_ENGINE AS

    PROCEDURE start_workflow(
        p_screen_alias   IN VARCHAR2,
        p_reference_id   IN VARCHAR2,
        p_user_id        IN VARCHAR2,
        p_screen_data    IN CLOB DEFAULT NULL
    ) IS
        v_cat_id        NUMBER;
        v_first_stage   NUMBER;
        v_workflow_id   NUMBER;
    BEGIN
        -- التحقق من وجود العملية المرتبطة بالشاشة
        SELECT cat_id INTO v_cat_id 
        FROM sys_process_cat 
        WHERE screen_alias = p_screen_alias AND is_active = 'Y';
        
        -- الحصول على المرحلة الأولى
        SELECT stage_id INTO v_first_stage
        FROM (
            SELECT stage_id 
            FROM sys_process_stage 
            WHERE cat_id = v_cat_id 
            ORDER BY stage_order
        ) WHERE ROWNUM = 1;
        
        -- إدخال سجل جديد في سير العمل
        INSERT INTO sys_workflow_data (
            cat_id, reference_id, current_stage, initiator_id, screen_data
        ) VALUES (
            v_cat_id, p_reference_id, v_first_stage, p_user_id, p_screen_data
        )
        RETURNING workflow_id INTO v_workflow_id;
        
        -- تسجيل التاريخ
        INSERT INTO sys_workflow_history (
            workflow_id, stage_id, action_type, action_by
        ) VALUES (
            v_workflow_id, v_first_stage, 'SUBMIT', p_user_id
        );
        
        -- إرسال إشعار للمعتمدين
        PKG_NOTIFICATION.send_stage_notification(v_workflow_id);
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'Workflow process not found for this screen');
    END start_workflow;
    
    PROCEDURE approve_action(
        p_workflow_id    IN NUMBER,
        p_user_id        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL
    ) IS
        v_current_stage  NUMBER;
        v_cat_id        NUMBER;
        v_next_stage    NUMBER;
        v_is_final      BOOLEAN;
    BEGIN
        -- التحقق من صلاحية المستخدم
        IF NOT PKG_WORKFLOW_UTILS.is_user_approver(p_user_id, p_workflow_id) THEN
            RAISE_APPLICATION_ERROR(-20002, 'User not authorized for approval');
        END IF;
        
        -- الحصول على المرحلة الحالية
        SELECT current_stage, cat_id INTO v_current_stage, v_cat_id
        FROM sys_workflow_data 
        WHERE workflow_id = p_workflow_id
        FOR UPDATE;
        
        -- تسجيل التاريخ
        INSERT INTO sys_workflow_history (
            workflow_id, stage_id, action_type, action_by, comments
        ) VALUES (
            p_workflow_id, v_current_stage, 'APPROVE', p_user_id, p_comments
        );
        
        -- التحقق إذا كانت المرحلة النهائية
        v_is_final := PKG_WORKFLOW_UTILS.is_final_stage(v_current_stage);
        
        IF v_is_final THEN
            -- تحديث الحالة النهائية
            UPDATE sys_workflow_data 
            SET status = 'APPROVED', last_update = SYSDATE
            WHERE workflow_id = p_workflow_id;
            
            -- إرسال إشعار نهائي
            PKG_NOTIFICATION.send_final_notification(p_workflow_id, 'APPROVED');
        ELSE
            -- الانتقال للمرحلة التالية
            v_next_stage := PKG_DYNAMIC_ROUTING.get_next_stage(p_workflow_id);
            
            -- تحديث المرحلة الحالية
            UPDATE sys_workflow_data 
            SET current_stage = v_next_stage, last_update = SYSDATE
            WHERE workflow_id = p_workflow_id;
            
            -- تسجيل المرحلة الجديدة
            INSERT INTO sys_workflow_history (
                workflow_id, stage_id, action_type, action_by, next_stage
            ) VALUES (
                p_workflow_id, v_current_stage, 'ADVANCE', 'SYSTEM', v_next_stage
            );
            
            -- إرسال إشعار للمرحلة الجديدة
            PKG_NOTIFICATION.send_stage_notification(p_workflow_id);
        END IF;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20003, 'Workflow not found');
    END approve_action;
    
    PROCEDURE reject_action(
        p_workflow_id    IN NUMBER,
        p_user_id        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL,
        p_target_stage   IN NUMBER DEFAULT NULL
    ) IS
        v_current_stage  NUMBER;
        v_cat_id        NUMBER;
        v_prev_stage    NUMBER;
    BEGIN
        -- التحقق من صلاحية المستخدم
        IF NOT PKG_WORKFLOW_UTILS.is_user_approver(p_user_id, p_workflow_id) THEN
            RAISE_APPLICATION_ERROR(-20002, 'User not authorized for rejection');
        END IF;
        
        -- الحصول على المرحلة الحالية
        SELECT current_stage, cat_id INTO v_current_stage, v_cat_id
        FROM sys_workflow_data 
        WHERE workflow_id = p_workflow_id
        FOR UPDATE;
        
        -- تسجيل التاريخ
        INSERT INTO sys_workflow_history (
            workflow_id, stage_id, action_type, action_by, comments
        ) VALUES (
            p_workflow_id, v_current_stage, 'REJECT', p_user_id, p_comments
        );
        
        -- تحديد المرحلة المستهدفة
        IF p_target_stage IS NOT NULL THEN
            v_prev_stage := p_target_stage;
        ELSE
            v_prev_stage := PKG_DYNAMIC_ROUTING.get_prev_stage(p_workflow_id);
        END IF;
        
        IF v_prev_stage IS NULL THEN
            -- رفض نهائي
            UPDATE sys_workflow_data 
            SET status = 'REJECTED', last_update = SYSDATE
            WHERE workflow_id = p_workflow_id;
            
            PKG_NOTIFICATION.send_final_notification(p_workflow_id, 'REJECTED');
        ELSE
            -- العودة للمرحلة السابقة
            UPDATE sys_workflow_data 
            SET current_stage = v_prev_stage, last_update = SYSDATE
            WHERE workflow_id = p_workflow_id;
            
            -- تسجيل العودة
            INSERT INTO sys_workflow_history (
                workflow_id, stage_id, action_type, action_by, next_stage
            ) VALUES (
                p_workflow_id, v_current_stage, 'ROLLBACK', 'SYSTEM', v_prev_stage
            );
            
            -- إرسال إشعار للمرحلة الجديدة
            PKG_NOTIFICATION.send_stage_notification(p_workflow_id);
        END IF;
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20003, 'Workflow not found');
    END reject_action;
    
    PROCEDURE delegate_approval(
        p_workflow_id    IN NUMBER,
        p_from_user      IN VARCHAR2,
        p_to_user        IN VARCHAR2,
        p_comments       IN VARCHAR2 DEFAULT NULL
    ) IS
        v_current_stage  NUMBER;
    BEGIN
        -- التحقق من صلاحية المستخدم
        IF NOT PKG_WORKFLOW_UTILS.is_user_approver(p_from_user, p_workflow_id) THEN
            RAISE_APPLICATION_ERROR(-20002, 'User not authorized to delegate');
        END IF;
        
        -- الحصول على المرحلة الحالية
        SELECT current_stage INTO v_current_stage
        FROM sys_workflow_data 
        WHERE workflow_id = p_workflow_id;
        
        -- تسجيل التفويض
        INSERT INTO sys_workflow_history (
            workflow_id, stage_id, action_type, action_by, comments
        ) VALUES (
            p_workflow_id, v_current_stage, 'DELEGATE', p_from_user, 
            'Delegated to ' || p_to_user || ': ' || p_comments
        );
        
        -- إرسال إشعار للمفوض إليه
        PKG_NOTIFICATION.send_delegation_notice(p_workflow_id, p_to_user);
        
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20003, 'Workflow not found');
    END delegate_approval;
    
    -- إجراءات أخرى سيتم تنفيذها بنفس النمط
    
END PKG_WORKFLOW_ENGINE;
/