-- Create some roles to play with in the tests

CREATE ROLE foo_role;
CREATE ROLE bar_role;

-- Check that auths_held and auth_diff work for a simple SELECT authority on
-- a table

CREATE TABLE foo (i integer NOT NULL);
GRANT SELECT ON TABLE foo TO foo_role;

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('foo_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 0::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 1::bigint));

-- Check that copy_auth transfers the SELECT authority and nothing else

SELECT copy_auth('foo_role', 'bar_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 0::bigint));

-- Check that remove_auth removes the SELECT authority

SELECT remove_auth('foo_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('foo_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 0::bigint));

-- Check that the same SELECT authority WITH GRANT OPTION counts as a
-- difference

GRANT SELECT ON TABLE foo TO foo_role WITH GRANT OPTION;

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('foo_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 1::bigint));

-- Check that copy_auth upgrades bar_role's SELECT authority

SELECT copy_auth('foo_role', 'bar_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'
    AND suffix = 'WITH GRANT OPTION'), 1::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auth_diff('foo_role', 'bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 0::bigint));

-- Check that move_auth does the same as copy_auth followed by remove_auth

SELECT remove_auth('foo_role');
SELECT remove_auth('bar_role');
GRANT SELECT ON TABLE foo TO foo_role;
SELECT move_auth('foo_role', 'bar_role');

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('foo_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'), 0::bigint));

VALUES (assert_equals((
    SELECT count(*)
    FROM auths_held('bar_role') AS t
    WHERE object_id = quote_ident(current_schema) || '.foo'
    AND suffix = ''), 1::bigint));

DROP TABLE foo;
DROP ROLE bar_role;
DROP ROLE foo_role;

-- vim: set et sw=4 sts=4:
