CREATE OR REPLACE PACKAGE NOTIFICATION_MGR_PKG AS

    -- إرسال إشعارات المجموعة
    PROCEDURE SEND_GROUP_NOTIFICATIONS(
        p_data_id          IN NUMBER,
        p_approve_group_id IN NUMBER
    );
    
    -- تحديث حالة الإشعار
    PROCEDURE MARK_NOTIFICATION_READ(
        p_notification_id IN NUMBER
    );
    
    -- إرسال إشعارات التصعيد
    PROCEDURE SEND_ESCALATION_NOTIFICATION(
        p_data_id        IN NUMBER,
        p_escalation_level IN NUMBER
    );
    
    -- جدولة الإشعارات المتكررة
    PROCEDURE SCHEDULE_REMINDERS;

END NOTIFICATION_MGR_PKG;
/

CREATE OR REPLACE PACKAGE BODY NOTIFICATION_MGR_PKG AS

    PROCEDURE SEND_GROUP_NOTIFICATIONS(
        p_data_id          IN NUMBER,
        p_approve_group_id IN NUMBER
    ) IS
        v_process_cat_id NUMBER;
        v_process_stage_id NUMBER;
    BEGIN
        SELECT PROCESS_CAT_ID, PROCESS_STAGE_ID 
        INTO v_process_cat_id, v_process_stage_id
        FROM SYS_APPROVE_GROUP
        WHERE APPROVE_GROUP_ID = p_approve_group_id;
        
        WORKFLOW_ENGINE_PKG.SEND_NOTIFICATION(p_data_id, v_process_stage_id);
    END SEND_GROUP_NOTIFICATIONS;
    
    PROCEDURE MARK_NOTIFICATION_READ(
        p_notification_id IN NUMBER
    ) IS
    BEGIN
        UPDATE SYS_ALARM_NOTIFICATION
        SET IS_READ = 1,
            IS_ACTIVE = 0
        WHERE SEQ_ID = p_notification_id;
    END MARK_NOTIFICATION_READ;
    
    PROCEDURE SCHEDULE_REMINDERS IS
        CURSOR unread_notifications IS
            SELECT n.SEQ_ID, n.EMPLOYEE_ID, n.ACTION_DATE,
                   d.REFERENCE_GUID, pc.PROCESS_CAT_NAME
            FROM SYS_ALARM_NOTIFICATION n
            JOIN SYS_PROCESS_CAT pc ON pc.PROCESS_CAT_ID = n.PROCESS_CAT_ID
            JOIN SYS_WORKFLOW_DATA d ON d.DATA_ID = n.PROCESS_STAGE_ID
            WHERE n.IS_READ = 0
            AND n.ACTION_DATE < SYSTIMESTAMP - INTERVAL '24' HOUR;
    BEGIN
        FOR notif IN unread_notifications LOOP
            -- إرسال تذكير
            INSERT INTO SYS_ALARM_NOTIFICATION (
                EMPLOYEE_ID, PROCESS_CAT_ID, PROCESS_STAGE_ID,
                NOTIFICATION_HEAD, NOTIFICATION_DESC, ESCALATION_LEVEL
            ) VALUES (
                notif.EMPLOYEE_ID, 
                (SELECT PROCESS_CAT_ID FROM SYS_ALARM_NOTIFICATION 
                 WHERE SEQ_ID = notif.SEQ_ID),
                (SELECT PROCESS_STAGE_ID FROM SYS_ALARM_NOTIFICATION 
                 WHERE SEQ_ID = notif.SEQ_ID),
                'تذكير: طلب بانتظار موافقتك',
                'طلب ' || notif.PROCESS_CAT_NAME || ' لا يزال بانتظار إجراء منك',
                1
            );
        END LOOP;
    END SCHEDULE_REMINDERS;

END NOTIFICATION_MGR_PKG;
/