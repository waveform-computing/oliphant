-- Check assert_raises operates correctly with a statement that raises a
-- specified exception

SELECT assert_raises('70001', $$
    DO $test$
        BEGIN
            RAISE EXCEPTION SQLSTATE '70001' USING MESSAGE = 'Foo';
        END;
    $test$;
$$);

-- Check assert_raises operates correctly when the statement raises a different
-- exception than expected

SELECT assert_raises('UTA01', $$
    DO $test1$
        BEGIN
            PERFORM assert_raises('70001', $perform$
                DO $test2$
                    BEGIN
                        RAISE EXCEPTION SQLSTATE '70000' USING MESSAGE = 'Foo';
                    END;
                $test2$;
            $perform$);
        END;
    $test1$;
$$);

-- Check assert_raises operates correctly when not exception is raised

SELECT assert_raises('UTA01', $$
    DO $test$
        BEGIN
            PERFORM assert_raises('70001', 'VALUES (now())');
        END;
    $test$
$$);

-- Check assert_equals operates correctly with a variety of types

VALUES (assert_equals(0, 0));
VALUES (assert_equals(0.0, 0.0));
VALUES (assert_equals(current_date, current_date));
VALUES (assert_equals(current_timestamp, current_timestamp));
VALUES (assert_equals(current_time, current_time));
VALUES (assert_equals('foo', 'foo'));
VALUES (assert_equals(1, NULL));

VALUES (assert_raises('UTA08', $$ VALUES (assert_equals(0, 1)) $$));
VALUES (assert_raises('UTA08', $$ VALUES (assert_equals(0.0, 1.0)) $$));
VALUES (assert_raises('UTA08', $$ VALUES (assert_equals(current_date, (current_date - interval '1 day')::date)) $$));
VALUES (assert_raises('UTA08', $$ VALUES (assert_equals(current_timestamp, current_timestamp + interval '1 microsecond')) $$));
VALUES (assert_raises('UTA08', $$ VALUES (assert_equals(current_time, current_time - interval '1 hour')) $$));
VALUES (assert_raises('UTA08', $$ VALUES (assert_equals('foo', 'bar')) $$));

VALUES (assert_not_equals(0, 1));
VALUES (assert_not_equals(0.0, 1.0));
VALUES (assert_not_equals(current_date, (current_date - interval '1 day')::date));
VALUES (assert_not_equals(current_timestamp, current_timestamp + interval '1 microsecond'));
VALUES (assert_not_equals(current_time, current_time - interval '1 hour'));
VALUES (assert_not_equals('foo', 'bar'));
VALUES (assert_not_equals(1, NULL));

VALUES (assert_raises('UTA09', $$ VALUES (assert_not_equals(0, 0)) $$));
VALUES (assert_raises('UTA09', $$ VALUES (assert_not_equals(0.0, 0.0)) $$));
VALUES (assert_raises('UTA09', $$ VALUES (assert_not_equals(current_date, current_date)) $$));
VALUES (assert_raises('UTA09', $$ VALUES (assert_not_equals(current_timestamp, current_timestamp)) $$));
VALUES (assert_raises('UTA09', $$ VALUES (assert_not_equals(current_time, current_time)) $$));
VALUES (assert_raises('UTA09', $$ VALUES (assert_not_equals('foo', 'foo')) $$));

VALUES (assert_is_null(NULL::integer));
VALUES (assert_is_null(NULL::float));
VALUES (assert_is_null(NULL::date));
VALUES (assert_is_null(NULL::timestamp));
VALUES (assert_is_null(NULL::time));
VALUES (assert_is_null(NULL::text));

VALUES (assert_raises('UTA06', $$ VALUES (assert_is_null(1)) $$));
VALUES (assert_raises('UTA06', $$ VALUES (assert_is_null(1.0)) $$));
VALUES (assert_raises('UTA06', $$ VALUES (assert_is_null(current_date)) $$));
VALUES (assert_raises('UTA06', $$ VALUES (assert_is_null(current_timestamp)) $$));
VALUES (assert_raises('UTA06', $$ VALUES (assert_is_null(current_time)) $$));
VALUES (assert_raises('UTA06', $$ VALUES (assert_is_null('foo')) $$));

VALUES (assert_is_not_null(1));
VALUES (assert_is_not_null(1.0));
VALUES (assert_is_not_null(current_date));
VALUES (assert_is_not_null(current_timestamp));
VALUES (assert_is_not_null(current_time));
VALUES (assert_is_not_null('foo'));

VALUES (assert_raises('UTA07', $$ VALUES (assert_is_not_null(NULL::integer)) $$));
VALUES (assert_raises('UTA07', $$ VALUES (assert_is_not_null(NULL::float)) $$));
VALUES (assert_raises('UTA07', $$ VALUES (assert_is_not_null(NULL::date)) $$));
VALUES (assert_raises('UTA07', $$ VALUES (assert_is_not_null(NULL::timestamp)) $$));
VALUES (assert_raises('UTA07', $$ VALUES (assert_is_not_null(NULL::time)) $$));
VALUES (assert_raises('UTA07', $$ VALUES (assert_is_not_null(NULL::text)) $$));

CREATE TABLE foo (i integer NOT NULL);

CREATE FUNCTION foo_insert_trigger()
    RETURNS trigger
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '70000',
        MESSAGE = 'You cannot insert into this table';
END;
$$;

CREATE TRIGGER foo_insert
    AFTER INSERT ON foo
    FOR EACH ROW
    EXECUTE PROCEDURE foo_insert_trigger();

CREATE FUNCTION foo_insert_attempt(i integer)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    INSERT INTO foo (i) VALUES (i);
$$;

VALUES (assert_table_exists('foo'));
VALUES (assert_table_exists(current_schema, 'foo'));
VALUES (assert_raises('UTA02', $$ VALUES (assert_table_exists('bar')) $$));

VALUES (assert_column_exists('foo', 'i'));
VALUES (assert_column_exists(current_schema, 'foo', 'i'));
VALUES (assert_raises('UTA03', $$ VALUES (assert_column_exists('foo', 'j')) $$));
VALUES (assert_raises('UTA02', $$ VALUES (assert_column_exists('bar', 'i')) $$));

VALUES (assert_trigger_exists('foo', 'foo_insert'));
VALUES (assert_trigger_exists(current_schema, 'foo', 'foo_insert'));
VALUES (assert_raises('UTA04', $$ VALUES (assert_trigger_exists('foo', 'foo_update')) $$));
VALUES (assert_raises('UTA02', $$ VALUES (assert_trigger_exists('bar', 'bar_insert')) $$));

VALUES (assert_function_exists('foo_insert_attempt', ARRAY ['integer']));
VALUES (assert_function_exists(current_schema, 'foo_insert_attempt', ARRAY ['integer']));
VALUES (assert_raises('UTA05', $$ VALUES (assert_function_exists('bar_insert_attempt', ARRAY ['integer'])) $$));

VALUES (assert_raises('70000', $$ SELECT foo_insert_attempt(1) $$));

DROP FUNCTION foo_insert_attempt(integer);
DROP TRIGGER foo_insert ON foo;
DROP FUNCTION foo_insert_trigger();
DROP TABLE foo;

-- vim: set et sw=4 sts=4:
