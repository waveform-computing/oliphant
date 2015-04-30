-- Create a base table to run tests on

CREATE TABLE foo (
    id integer NOT NULL PRIMARY KEY,
    value integer NOT NULL
);

INSERT INTO foo (id, value) VALUES (1, 1);

-- Create a history table from the base table and ensure it exists, and has
-- the expected structure

SELECT create_history_table('foo', 'day');
SELECT assert_table_exists('foo_history');
VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_history'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'effective'),
            (2, 'expiry'),
            (3, 'id'),
            (4, 'value')
    ) AS t)));

-- Create the triggers to link the base table to the history table and ensure
-- all the expected triggers get created

SELECT create_history_triggers('foo', 'day');
SELECT assert_trigger_exists('foo', 'foo_insert');
SELECT assert_trigger_exists('foo', 'foo_update');
SELECT assert_trigger_exists('foo', 'foo_delete');
SELECT assert_trigger_exists('foo', 'foo_truncate');
SELECT assert_trigger_exists('foo', 'foo_keychg');

-- Create a changes view on the history table and ensure it has the expected
-- structure

SELECT create_history_changes('foo_history');
SELECT assert_table_exists('foo_changes');
VALUES (assert_equals(6::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_changes'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'changed'),
            (2, 'change'),
            (3, 'old_id'),
            (4, 'new_id'),
            (5, 'old_value'),
            (6, 'new_value')
    ) AS t)));

-- Ensure the triggers are working correctly by manipulating the base table
-- and checking the content of the history table. This test assumes we are
-- running within an extended transaction and that therefore the values of
-- current_date, current_timestamp, etc. will always be equal

INSERT INTO foo VALUES (2, 2);
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date, date '9999-12-31', 1, 1),
            (current_date, date '9999-12-31', 2, 2)
    ) AS t)));

DELETE FROM foo WHERE id = 1;
VALUES (assert_equals(1::bigint, (SELECT count(*) FROM foo_history)));

-- We cheat a bit here by manipulating the effective date in the history table
-- but it's the easiest way to test the other half of the update & delete
-- triggers

INSERT INTO foo (id,value) VALUES (1, 1);
UPDATE foo_history SET effective = current_date - interval '1 day' WHERE id = 1;
DELETE FROM foo WHERE id = 1;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date,                    date '9999-12-31',               2, 2)
    ) AS t)));

UPDATE foo SET value = 1 WHERE id = 2;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date,                    date '9999-12-31',               2, 1)
    ) AS t)));

UPDATE foo SET value = 2 WHERE id = 2;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date,                    date '9999-12-31',               2, 2)
    ) AS t)));

-- Again, we cheat and tweak the history to pretend the id=2 row was inserted
-- yesterday

UPDATE foo_history SET effective = current_date - interval '1 day' WHERE id = 2;
UPDATE foo SET value = 1 WHERE id = 2;
VALUES (assert_equals(3::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date - interval '1 day', current_date - interval '1 day', 2, 2),
            (current_date,                    date '9999-12-31',               2, 1)
    ) AS t)));

-- Ensure the changes view has represented everything accurately

VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_changes

        INTERSECT

        VALUES
            (current_date - interval '1 day', 'INSERT', NULL, 1,    NULL, 1),
            (current_date,                    'DELETE', 1,    NULL, 1,    NULL),
            (current_date - interval '1 day', 'INSERT', NULL, 2,    NULL, 2),
            (current_date,                    'UPDATE', 2,    2,    2,    1)
    ) AS t)));

-- Ensure the keychg trigger is operational

SELECT assert_raises('UTH01', 'UPDATE foo SET id = 4 WHERE id = 2');

-- Ensure the truncate trigger is operational

TRUNCATE foo;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date - interval '1 day', current_date - interval '1 day', 2, 2)
    ) AS t)));

DROP VIEW foo_changes;
DROP TABLE foo_history;
SELECT drop_history_triggers('foo');
DELETE FROM foo;

-- Test microsecond resolution

SELECT create_history_table('foo', 'microsecond');
SELECT assert_table_exists('foo_history');
VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_history'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'effective'),
            (2, 'expiry'),
            (3, 'id'),
            (4, 'value')
    ) AS t)));

SELECT create_history_triggers('foo', 'microsecond');
SELECT assert_trigger_exists('foo', 'foo_insert');
SELECT assert_trigger_exists('foo', 'foo_update');
SELECT assert_trigger_exists('foo', 'foo_delete');
SELECT assert_trigger_exists('foo', 'foo_truncate');
SELECT assert_trigger_exists('foo', 'foo_keychg');

SELECT create_history_changes('foo_history');
SELECT assert_table_exists('foo_changes');
VALUES (assert_equals(6::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_changes'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'changed'),
            (2, 'change'),
            (3, 'old_id'),
            (4, 'new_id'),
            (5, 'old_value'),
            (6, 'new_value')
    ) AS t)));

INSERT INTO foo (id, value) VALUES (1, 1);
VALUES (assert_equals(1::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_timestamp, timestamp '9999-12-31 23:59:59.999999', 1, 1)
    ) AS t)));

INSERT INTO foo (id, value) VALUES (2, 1);
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_timestamp, timestamp '9999-12-31 23:59:59.999999', 1, 1),
            (current_timestamp, timestamp '9999-12-31 23:59:59.999999', 2, 1)
    ) AS t)));

UPDATE foo_history SET effective = effective - interval '1 second';
DELETE FROM foo WHERE id = 1;
UPDATE foo SET value = 2 WHERE id = 2;
VALUES (assert_equals(3::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_timestamp - interval '1 second', current_timestamp - interval '1 microsecond', 1, 1),
            (current_timestamp - interval '1 second', current_timestamp - interval '1 microsecond', 2, 1),
            (current_timestamp,                       timestamp '9999-12-31 23:59:59.999999',       2, 2)
    ) AS t)));

VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_changes

        INTERSECT

        VALUES
            (current_timestamp - interval '1 second', 'INSERT', NULL, 1,    NULL, 1),
            (current_timestamp,                       'DELETE', 1,    NULL, 1,    NULL),
            (current_timestamp - interval '1 second', 'INSERT', NULL, 2,    NULL, 1),
            (current_timestamp,                       'UPDATE', 2,    2,    1,    2)
    ) AS t)));

TRUNCATE foo;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_timestamp - interval '1 second', current_timestamp - interval '1 microsecond', 1, 1),
            (current_timestamp - interval '1 second', current_timestamp - interval '1 microsecond', 2, 1)
    ) AS t)));

DROP VIEW foo_changes;
SELECT drop_history_triggers('foo');
DROP TABLE foo_history;

SELECT create_history_table('foo', 'week');
SELECT assert_table_exists('foo_history');
VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_history'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'effective'),
            (2, 'expiry'),
            (3, 'id'),
            (4, 'value')
    ) AS t)));

SELECT create_history_triggers('foo', 'week', interval '-7 days');
SELECT assert_trigger_exists('foo', 'foo_insert');
SELECT assert_trigger_exists('foo', 'foo_update');
SELECT assert_trigger_exists('foo', 'foo_delete');
SELECT assert_trigger_exists('foo', 'foo_truncate');
SELECT assert_trigger_exists('foo', 'foo_keychg');

INSERT INTO foo VALUES (1, 1);
VALUES (assert_equals(1::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (date_trunc('week', current_date) - interval '7 days', date '9999-12-31', 1, 1)
    ) AS t)));

SELECT drop_history_triggers('foo');
DROP TABLE foo_history;
DROP TABLE foo;

-- Test that operation works with tables that are "all key, no attributes"

CREATE TABLE foo (
    foo_id integer NOT NULL,
    bar_id integer NOT NULL,
    CONSTRAINT foo_pk PRIMARY KEY (foo_id, bar_id)
);

SELECT create_history_table('foo', 'day');
SELECT assert_table_exists('foo_history');
VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_history'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'effective'),
            (2, 'expiry'),
            (3, 'foo_id'),
            (4, 'bar_id')
    ) AS t)));

SELECT create_history_triggers('foo', 'day');
SELECT assert_trigger_exists('foo', 'foo_insert');
SELECT assert_trigger_exists('foo', 'foo_delete');
SELECT assert_trigger_exists('foo', 'foo_truncate');
SELECT assert_trigger_exists('foo', 'foo_keychg');

INSERT INTO foo (foo_id, bar_id) VALUES (1, 1);
VALUES (assert_equals(1::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date, date '9999-12-31', 1, 1)
    ) AS t)));

SELECT assert_raises('UTH01', 'UPDATE foo SET bar_id = 2 WHERE foo_id = 1 AND bar_id = 1');

DELETE FROM foo WHERE foo_id = 1 AND bar_id = 1;
VALUES (assert_equals(0::bigint, (SELECT count(*) FROM foo_history)));

SELECT drop_history_triggers('foo');
DROP TABLE foo_history;
DROP TABLE foo;

-- Test that operation works with tables that have mismatched attributes

CREATE TABLE foo (
    id integer NOT NULL PRIMARY KEY,
    value integer NOT NULL,
    ignored text NOT NULL
);

INSERT INTO foo (id, value, ignored) VALUES (1, 1, 'foo');

SELECT create_history_table('foo', 'day');
SELECT assert_table_exists('foo_history');

-- Remove the "ignored" column and ensure everything still operates as expected
ALTER TABLE foo_history DROP COLUMN ignored;
VALUES (assert_equals(4::bigint, (
    SELECT count(*)
    FROM (
        SELECT attnum, attname
        FROM pg_catalog.pg_attribute
        WHERE attrelid = 'foo_history'::regclass
        AND attnum > 0

        INTERSECT

        VALUES
            (1, 'effective'),
            (2, 'expiry'),
            (3, 'id'),
            (4, 'value')
    ) AS t)));

SELECT create_history_triggers('foo', 'day');
SELECT assert_trigger_exists('foo', 'foo_insert');
SELECT assert_trigger_exists('foo', 'foo_update');
SELECT assert_trigger_exists('foo', 'foo_delete');
SELECT assert_trigger_exists('foo', 'foo_truncate');
SELECT assert_trigger_exists('foo', 'foo_keychg');

INSERT INTO foo VALUES (2, 2, 'bar');
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date, date '9999-12-31', 1, 1),
            (current_date, date '9999-12-31', 2, 2)
    ) AS t)));

DELETE FROM foo WHERE id = 1;
VALUES (assert_equals(1::bigint, (SELECT count(*) FROM foo_history)));

INSERT INTO foo (id, value, ignored) VALUES (1, 1, 'baz');
UPDATE foo_history SET effective = current_date - interval '1 day' WHERE id = 1;
DELETE FROM foo WHERE id = 1;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date,                    date '9999-12-31',               2, 2)
    ) AS t)));

UPDATE foo SET value = 1 WHERE id = 2;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date,                    date '9999-12-31',               2, 1)
    ) AS t)));

UPDATE foo SET value = 2 WHERE id = 2;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date,                    date '9999-12-31',               2, 2)
    ) AS t)));

UPDATE foo_history SET effective = current_date - interval '1 day' WHERE id = 2;
UPDATE foo SET value = 1 WHERE id = 2;
VALUES (assert_equals(3::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date - interval '1 day', current_date - interval '1 day', 2, 2),
            (current_date,                    date '9999-12-31',               2, 1)
    ) AS t)));

SELECT assert_raises('UTH01', 'UPDATE foo SET id = 4 WHERE id = 2');

TRUNCATE foo;
VALUES (assert_equals(2::bigint, (
    SELECT count(*)
    FROM (
        SELECT * FROM foo_history

        INTERSECT

        VALUES
            (current_date - interval '1 day', current_date - interval '1 day', 1, 1),
            (current_date - interval '1 day', current_date - interval '1 day', 2, 2)
    ) AS t)));

DROP TABLE foo_history;
SELECT drop_history_triggers('foo');
DROP TABLE foo;
