-- Create some roles to play with in the tests

CREATE ROLE foo_role;
CREATE ROLE bar_role;

-- Check that role_auths and auth_diff work for a simple SELECT authority on
-- a table

CREATE TABLE foo (i integer NOT NULL);
GRANT SELECT ON TABLE foo TO foo_role;

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('foo_role') AS t
    WHERE object_id = 'foo'::regclass), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('bar_role') AS t
    WHERE object_id = 'foo'::regclass), 0::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = 'foo'::regclass), 1::bigint));

-- Check that copy_role_auths transfers the SELECT authority and nothing else

SELECT copy_role_auths('foo_role', 'bar_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('bar_role') AS t
    WHERE object_id = 'foo'::regclass), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = 'foo'::regclass), 0::bigint));

-- Check that remove_role_auths removes the SELECT authority

SELECT remove_role_auths('foo_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('foo_role') AS t
    WHERE object_id = 'foo'::regclass), 0::bigint));

-- Check that the same SELECT authority WITH GRANT OPTION counts as a
-- difference

GRANT SELECT ON TABLE foo TO foo_role WITH GRANT OPTION;

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('foo_role') AS t
    WHERE object_id = 'foo'::regclass), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = 'foo'::regclass), 1::bigint));

-- Check that copy_role_auths upgrades bar_role's SELECT authority

SELECT copy_role_auths('foo_role', 'bar_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('bar_role') AS t
    WHERE object_id = 'foo'::regclass
    AND suffix = 'WITH GRANT OPTION'), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = 'foo'::regclass), 0::bigint));

-- Check that move_role_auths does the same as copy_role_auths followed by remove_role_auths

SELECT remove_role_auths('foo_role');
SELECT remove_role_auths('bar_role');
GRANT SELECT ON TABLE foo TO foo_role;
SELECT move_role_auths('foo_role', 'bar_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('foo_role') AS t
    WHERE object_id = 'foo'::regclass), 0::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM role_auths('bar_role') AS t
    WHERE object_id = 'foo'::regclass
    AND suffix = ''), 1::bigint));

DROP TABLE foo;
DROP ROLE bar_role;
DROP ROLE foo_role;

-- XXX Add tests for function grants

-- vim: set et sw=4 sts=4:
