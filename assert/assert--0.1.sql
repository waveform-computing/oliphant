-------------------------------------------------------------------------------
-- ASSERTION FRAMEWORK
-------------------------------------------------------------------------------
-- Copyright (c) 2014-2015 Dave Jones <dave@waveform.org.uk>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to
-- deal in the Software without restriction, including without limitation the
-- rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
-- sell copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
-- IN THE SOFTWARE.
-------------------------------------------------------------------------------

-- Complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION assert" to load this file. \quit

-- assert_raises(state, sql)
-------------------------------------------------------------------------------
-- Raises an exception if executing the specified SQL does NOT raise SQLSTATE
-- state. The specified SQL must be capable of being executed by EXECUTE with
-- no extra parameters (INTO, USING, etc.)
-------------------------------------------------------------------------------

CREATE FUNCTION assert_raises(state char(5), sql text)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
BEGIN
    BEGIN
        EXECUTE sql;
    EXCEPTION
        WHEN others THEN
            IF SQLSTATE = state THEN
                RETURN;
            END IF;
            RAISE EXCEPTION USING
                ERRCODE = 'UTA01',
                MESSAGE = format('%s signalled SQLSTATE %s instead of %s',
                    LEFT(sql, 80) || CASE WHEN length(sql) > 80 THEN '...' ELSE '' END,
                    SQLSTATE, state);
    END;
    RAISE EXCEPTION USING
        ERRCODE = 'UTA01',
        MESSAGE = format('%s did not signal SQLSTATE %s',
            LEFT(sql, 80) || CASE WHEN length(sql) > 80 THEN '...' ELSE '' END,
            state);
END;
$$;

COMMENT ON FUNCTION assert_raises(char, text)
    IS 'Raises an exception if the execution of sql doesn''t signal SQLSTATE state, or signals a different SQLSTATE';

-- assert_table_exists(aschema, atable)
-- assert_table_exists(atable)
-------------------------------------------------------------------------------
-- Raises an exception if the table or view aschema.atable does not exist, or
-- is not a table/view. If not specified, aschema defaults to the value of the
-- current_schema.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_table_exists(aschema name, atable name)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
BEGIN
    PERFORM (quote_ident(aschema) || '.' || quote_ident(atable))::regclass;
EXCEPTION
    WHEN undefined_table THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA02',
            MESSAGE = format('Table %I.%I does not exist', aschema, atable);
END;
$$;

CREATE FUNCTION assert_table_exists(atable name)
    RETURNS void
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (assert_table_exists(current_schema, atable));
$$;

COMMENT ON FUNCTION assert_table_exists(name, name)
    IS 'Raises an exception if the specified table does not exist';
COMMENT ON FUNCTION assert_table_exists(name)
    IS 'Raises an exception if the specified table does not exist';

-- assert_column_exists(aschema, atable, acolumn)
-- assert_column_exists(atable, acolumn)
-------------------------------------------------------------------------------
-- Raises an exception if acolumn does not exist within the relation
-- aschema.atable. If not specified, aschema defaults to the value of the
-- current_schema.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_column_exists(aschema name, atable name, acolumn name)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    source_oid regclass;
BEGIN
    source_oid := (quote_ident(aschema) || '.' || quote_ident(atable))::regclass;
    IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_attribute
            WHERE attrelid = source_oid AND attname = acolumn
        ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA03',
            MESSAGE = format('Column %I.%I.%I does not exist', aschema, atable, acolumn);
    END IF;
EXCEPTION
    WHEN undefined_table THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA02',
            MESSAGE = format('Table %I.%I does not exist', aschema, atable);
END;
$$;

CREATE FUNCTION assert_column_exists(atable name, acolumn name)
    RETURNS void
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (assert_column_exists(current_schema, atable, acolumn));
$$;

COMMENT ON FUNCTION assert_column_exists(name, name, name)
    IS 'Raises an exception if the specified column does not exist';
COMMENT ON FUNCTION assert_column_exists(name, name)
    IS 'Raises an exception if the specified column does not exist';

-- assert_trigger_exists(aschema, atable, atrigger)
-- assert_trigger_exists(atable, atrigger)
-------------------------------------------------------------------------------
-- Raises an exception if atrigger does not exist on the relation
-- aschema.atable. If not specified, aschema defaults to the value of the
-- current_schema.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_trigger_exists(aschema name, atable name, atrigger name)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    source_oid regclass;
BEGIN
    source_oid := (quote_ident(aschema) || '.' || quote_ident(atable))::regclass;
    IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_trigger
            WHERE tgrelid = source_oid AND tgname = atrigger
        ) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA04',
            MESSAGE = format('Trigger %I does not exist on table %I.%I', atrigger, aschema, atable);
    END IF;
EXCEPTION
    WHEN undefined_table THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA02',
            MESSAGE = format('Table %I.%I does not exist', aschema, atable);
END;
$$;

CREATE FUNCTION assert_trigger_exists(atable name, atrigger name)
    RETURNS void
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (assert_trigger_exists(current_schema, atable, atrigger));
$$;

COMMENT ON FUNCTION assert_trigger_exists(name, name, name)
    IS 'Raises an exception if the specified trigger does not exist';
COMMENT ON FUNCTION assert_trigger_exists(name, name)
    IS 'Raises an exception if the specified trigger does not exist';

-- assert_function_exists(aschema, afunction, argtypes)
-- assert_function_exists(afunction, argtypes)
-------------------------------------------------------------------------------
-- Raises an exception if afunction does not exist with the specified argument
-- types. If not specified, aschema defaults to the value of the
-- current_schema.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_function_exists(aschema name, afunction name, argtypes name[])
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
BEGIN
    PERFORM (
        quote_ident(aschema) || '.' || quote_ident(afunction) ||
            '(' || array_to_string(argtypes, ',') || ')')::regprocedure;
EXCEPTION
    WHEN undefined_function THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA05',
            MESSAGE = format('Function %I.%I(%s) does not exist',
                aschema, afunction, array_to_string(argtypes, ','));
END;
$$;

CREATE FUNCTION assert_function_exists(afunction name, argtypes name[])
    RETURNS void
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (assert_function_exists(current_schema, afunction, argtypes));
$$;

COMMENT ON FUNCTION assert_function_exists(name, name, name[])
    IS 'Raises an exception if the specified function does not exist';
COMMENT ON FUNCTION assert_function_exists(name, name[])
    IS 'Raises an exception if the specified function does not exist';

-- assert_is_null(a)
-------------------------------------------------------------------------------
-- Raises an exception if a is not NULL. The function is overloaded for most
-- common types and generally should not need CASTs for usage.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_is_null(a anyelement)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA06',
            MESSAGE = a::text || ' is not NULL';
    END IF;
END;
$$;

CREATE FUNCTION assert_is_null(a text)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA06',
            MESSAGE = a::text || ' is not NULL';
    END IF;
END;
$$;

COMMENT ON FUNCTION assert_is_null(anyelement)
    IS 'Raises an exception if the specified value is not NULL';
COMMENT ON FUNCTION assert_is_null(text)
    IS 'Raises an exception if the specified value is not NULL';

-- assert_is_not_null(a)
-------------------------------------------------------------------------------
-- Raises an exception if a is NULL. The function is overloaded for most common
-- types and generally should not need CASTs for usage.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_is_not_null(a anyelement)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA07',
            MESSAGE = 'value is NULL';
    END IF;
END;
$$;

CREATE FUNCTION assert_is_not_null(a text)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA07',
            MESSAGE = 'value is NULL';
    END IF;
END;
$$;

COMMENT ON FUNCTION assert_is_not_null(anyelement)
    IS 'Raises an exception if the specified value is NULL';
COMMENT ON FUNCTION assert_is_not_null(text)
    IS 'Raises an exception if the specified value is NULL';

-- assert_equals(a, b)
-------------------------------------------------------------------------------
-- Raises an exception if a does not equal b. The function is overloaded for
-- most common types and generally should not need CASTs for usage.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_equals(a anyelement, b anyelement)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a <> b THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA08',
            MESSAGE = a::text || ' does not equal ' || b::text;
    END IF;
END;
$$;

CREATE FUNCTION assert_equals(a text, b text)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a <> b THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA08',
            MESSAGE = a::text || ' does not equal ' || b::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION assert_equals(anyelement, anyelement)
    IS 'Raises an exception if a does not equal b';
COMMENT ON FUNCTION assert_equals(text, text)
    IS 'Raises an exception if a does not equal b';

-- assert_not_equals(a, b)
-------------------------------------------------------------------------------
-- Raises an exception if a does not equal b. The function is overloaded for
-- most common types and generally should not need CASTs for usage.
-------------------------------------------------------------------------------

CREATE FUNCTION assert_not_equals(a anyelement, b anyelement)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a = b THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA09',
            MESSAGE = a::text || ' equals ' || b::text;
    END IF;
END;
$$;

CREATE FUNCTION assert_not_equals(a text, b text)
    RETURNS void
    LANGUAGE plpgsql
    IMMUTABLE
AS $$
BEGIN
    IF a = b THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTA09',
            MESSAGE = a::text || ' equals ' || b::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION assert_not_equals(anyelement, anyelement)
    IS 'Raises an exception if a equals b';
COMMENT ON FUNCTION assert_not_equals(text, text)
    IS 'Raises an exception if a equals b';

-- vim: set et sw=4 sts=4:
