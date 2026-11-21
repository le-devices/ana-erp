-- 062 — Live screens (spec 062, D3): a new task or process notice wakes its user's screens; a system or
-- scheduler notice wakes the bells (each screen then reads only what it may see).
CREATE FUNCTION bpm.wake_user() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_wake', 'user:' || NEW.username);
    RETURN NULL;
END $$;
CREATE TRIGGER notification_wake AFTER INSERT ON bpm.notification FOR EACH ROW EXECUTE FUNCTION bpm.wake_user();
CREATE FUNCTION ana_system.wake_notices() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_wake', 'notices');
    RETURN NULL;
END $$;
CREATE TRIGGER notice_wake AFTER INSERT ON ana_system.notice FOR EACH STATEMENT EXECUTE FUNCTION ana_system.wake_notices();
CREATE TRIGGER scheduler_notification_wake AFTER INSERT ON scheduler.notification FOR EACH STATEMENT
    EXECUTE FUNCTION ana_system.wake_notices();
