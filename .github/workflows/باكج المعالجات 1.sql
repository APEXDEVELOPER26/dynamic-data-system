CREATE OR REPLACE PACKAGE DYNAMIC_WORKFLOW_PKG AS
    -- بدء عملية سير عمل جديدة
    PROCEDURE START_WORKFLOW(
        p_process_cat      IN NUMBER,
        p_process_stage    IN NUMBER,
        p_reference_guid   IN VARCHAR2,
        p_initiator        IN VARCHAR2,
        p_tbl_name         IN VARCHAR2,
        p_page_no          IN NUMBER,
        p_branch_id        IN NUMBER,
        p_data_id          OUT NUMBER
    );
    
    -- الموافقة على مرحلة
    PROCEDURE APPROVE_STAGE(
        p_data_id          IN NUMBER,
        p_approver         IN VARCHAR2,
        p_comments         IN CLOB DEFAULT NULL
    );
    
    -- رفض المرحلة
    PROCEDURE REJECT_STAGE(
        p_data_id          IN NUMBER,
        p_rejecter         IN VARCHAR2,
        p_comments         IN CLOB DEFAULT NULL,
        p_target_stage     IN NUMBER DEFAULT NULL
    );
    
    -- استرجاع المرحلة
    PROCEDURE ROLLBACK_STAGE(
        p_data_id          IN NUMBER,
        p_rollback_by      IN VARCHAR2,
        p_target_stage     IN NUMBER,
        p_comments         IN CLOB DEFAULT NULL
    );
    
    -- إضافة تعليق جديد
    PROCEDURE ADD_COMMENT(
        p_data_id          IN NUMBER,
        p_user             IN VARCHAR2,
        p_comment          IN CLOB
    );
    
    -- تغيير مرحلة العملية
    PROCEDURE CHANGE_STAGE(
        p_data_id          IN NUMBER,
        p_new_stage        IN NUMBER,
        p_changed_by       IN VARCHAR2,
        p_reason           IN VARCHAR2
    );
    
    -- تعليق العملية
    PROCEDURE SUSPEND_PROCESS(
        p_data_id          IN NUMBER,
        p_suspended_by     IN VARCHAR2,
        p_reason           IN VARCHAR2
    );
    
    -- استئناف العملية
    PROCEDURE RESUME_PROCESS(
        p_data_id          IN NUMBER,
        p_resumed_by       IN VARCHAR2
    );
    
    -- التصعيد التلقائي للمراحل المتأخرة
    PROCEDURE AUTO_ESCALATE;
    
    -- إنشاء مجموعة موافقة جديدة
    PROCEDURE CREATE_APPROVE_GROUP(
        p_process_cat      IN NUMBER,
        p_process_stage    IN NUMBER,
        p_group_name       IN VARCHAR2,
        p_description      IN VARCHAR2,
        p_approve_group_id OUT NUMBER
    );
    
    -- إضافة معيار موافقة
    PROCEDURE ADD_APPROVAL_CRITERIA(
        p_approve_group_id IN NUMBER,
        p_criteria_type    IN VARCHAR2,
        p_position_value   IN NUMBER,
        p_approve_type     IN NUMBER
    );
    
    -- إرسال إشعار
    PROCEDURE SEND_NOTIFICATION(
        p_data_id          IN NUMBER,
        p_notification_type IN VARCHAR2,
        p_message          IN VARCHAR2
    );
    
    -- الحصول على معلومات المرحلة الحالية
    FUNCTION GET_CURRENT_STAGE_INFO(
        p_data_id          IN NUMBER
    ) RETURN SYS_REFCURSOR;
    
    -- الحصول على تاريخ العملية
    FUNCTION GET_PROCESS_HISTORY(
        p_data_id          IN NUMBER
    ) RETURN SYS_REFCURSOR;
END DYNAMIC_WORKFLOW_PKG;
/