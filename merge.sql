-------------------------------------------------------------------------------
-- MERGE UTILITIES
-------------------------------------------------------------------------------
-- Copyright (c) 2014 Dave Hughes <dave@waveform.org.uk>
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
-- The following routines permit easy construction of MERGE-like instructions
-- for the purpose of bulk upserts from a source table to a similarly
-- structured destination table.
-------------------------------------------------------------------------------

-- ROLES
-------------------------------------------------------------------------------
-- The following roles grant usage and administrative rights to the objects
-- created by this module.
-------------------------------------------------------------------------------

DROP ROLE IF EXISTS utils_merge_user;
DROP ROLE IF EXISTS utils_merge_admin;
CREATE ROLE utils_merge_user;
CREATE ROLE utils_merge_admin;

GRANT utils_merge_user TO utils_user;
GRANT utils_merge_user TO utils_merge_admin WITH ADMIN OPTION;
GRANT utils_merge_admin TO utils_admin WITH ADMIN OPTION;

-- x_build_insert(source_schema, source_table, dest_schema, dest_table)
-- x_build_merge(source_schema, source_table, dest_schema, dest_table, dest_key)
-- x_build_delete(source_schema, source_table, dest_schema, dest_table, dest_key)
-- x_merge_checks(source_schema, source_table, dest_schema, dest_table, dest_key)
-------------------------------------------------------------------------------
-- These functions are effectively private utility subroutines for the
-- procedures defined below. They simply generate snippets of SQL given a set
-- of input parameters.
-------------------------------------------------------------------------------

CREATE FUNCTION x_build_insert(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    cols text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            t.attname
        FROM
            pg_catalog.pg_attribute s
            JOIN pg_catalog.pg_attribute t
                ON s.attname = t.attname
        WHERE
            s.attrelid = table_oid(source_schema, source_table)
            AND t.attrelid = table_oid(dest_schema, dest_table)
            AND t.attnum > 0
    LOOP
        cols := cols || ',' || quote_ident(r.attname);
    END LOOP;
    cols := substring(cols from 2);

    RETURN
        'INSERT INTO ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' '
        || '(' || cols || ') '
        || 'SELECT ' || cols || ' '
        || 'FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table);
END;
$$;

CREATE FUNCTION x_build_update(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_key name
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    set_cols text DEFAULT '';
    where_cols text DEFAULT '';
    return_cols text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            t.attname,
            ARRAY [t.attnum] <@ c.conkey AS iskey
        FROM
            pg_catalog.pg_attribute s
            JOIN pg_catalog.pg_attribute t
                ON s.attname = t.attname
            JOIN pg_catalog.pg_constraint c
                ON c.conrelid = t.attrelid
        WHERE
            s.attrelid = table_oid(source_schema, source_table)
            AND t.attrelid = table_oid(dest_schema, dest_table)
            AND t.attnum > 0
            AND c.contype IN ('p', 'u')
            -- XXX what about connamespace?
            AND c.conname = dest_key
    LOOP
        IF r.iskey THEN
            where_cols := where_cols || ' AND src.' || quote_ident(r.attname) || ' = dest.' || quote_ident(r.attname);
            return_cols := return_cols || ',src.' || quote_ident(r.attname);
        ELSE
            set_cols := set_cols || ',' || quote_ident(r.attname) || ' = src.' || quote_ident(r.attname);
        END IF;
    END LOOP;

    RETURN
        'UPDATE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' AS dest '
        || 'SET ' || substring(set_cols from 2) || ' '
        || 'FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' AS src '
        || 'WHERE ' || substring(where_cols from 6) || ' '
        || 'RETURNING ' || substring(return_cols from 2);
END;
$$;

CREATE FUNCTION x_build_delete(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_key name
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    key_cols text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            t.attname
        FROM
            pg_catalog.pg_attribute t
            JOIN pg_catalog.pg_constraint c
                ON c.conrelid = t.attrelid
        WHERE
            t.attrelid = table_oid(dest_schema, dest_table)
            AND t.attnum > 0
            AND c.contype IN ('p', 'u')
            -- XXX what about connamespace?
            AND c.conname = dest_key
            AND ARRAY [t.attnum] <@ c.conkey
    LOOP
        key_cols := key_cols || ',' || quote_ident(r.attname);
    END LOOP;
    key_cols := substring(key_cols from 2);

    RETURN
        'DELETE FROM ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' '
        || 'WHERE ROW (' || key_cols || ') IN ('
        || 'SELECT ' || key_cols || ' '
        || 'FROM ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' '
        || 'EXCEPT '
        || 'SELECT ' || key_cols || ' '
        || 'FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table)
        || ')';
END;
$$;

CREATE FUNCTION x_build_merge(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_key name
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    key_cols text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            t.attname
        FROM
            pg_catalog.pg_attribute t
            JOIN pg_catalog.pg_constraint c
                ON c.conrelid = t.attrelid
        WHERE
            t.attrelid = table_oid(dest_schema, dest_table)
            AND t.attnum > 0
            AND c.contype IN ('p', 'u')
            -- XXX what about connamespace?
            AND c.conname = dest_key
            AND ARRAY [t.attnum] <@ c.conkey
    LOOP
        key_cols := key_cols || ',' || quote_ident(r.attname);
    END LOOP;
    key_cols := substring(key_cols from 2);

    RETURN
        'WITH upsert AS ('
        || x_build_update(source_schema, source_table, dest_schema, dest_table, dest_key)
        || ')'
        || x_build_insert(source_schema, source_table, dest_schema, dest_table) || ' '
        || 'WHERE ROW (' || key_cols || ') NOT IN ('
        ||     'SELECT ' || key_cols || ' '
        ||     'FROM upsert'
        || ')';
END;
$$;

CREATE FUNCTION x_insert_checks(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name
)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
BEGIN
    PERFORM assert_table_exists(source_schema, source_table);
    PERFORM assert_table_exists(dest_schema, dest_table);

    IF table_oid(source_schema, source_table) = table_oid(dest_schema, dest_table) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTM01',
            MESSAGE = 'Source and destination tables cannot be the same',
            TABLE = table_oid(source_schema, source_table);
    END IF;
END;
$$;

CREATE FUNCTION x_merge_checks(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_key name
)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    r record;
BEGIN
    PERFORM x_insert_checks(source_schema, source_table, dest_schema, dest_table);

    FOR r IN
        SELECT
            s.attname
        FROM
            pg_catalog.pg_attribute t
            JOIN pg_catalog.pg_constraint c
                ON c.conrelid = t.attrelid
            LEFT JOIN pg_catalog.pg_attribute s
                ON s.attname = t.attname
        WHERE
            s.attrelid = table_oid(source_schema, source_table)
            AND t.attrelid = table_oid(dest_schema, dest_table)
            AND t.attnum > 0
            AND c.contype IN ('p', 'u')
            -- XXX what about connamespace?
            AND c.conname = dest_key
            AND ARRAY [t.attnum] <@ c.conkey
            AND s.attname IS NULL
    LOOP
        RAISE EXCEPTION USING
            ERRCODE = 'UTM02',
            MESSAGE = 'All fields of constraint ' || dest_key || ' must exist in the source and target tables',
            TABLE = table_oid(dest_schema, dest_table);
    END LOOP;
END;
$$;

-- auto_insert(source_schema, source_table, dest_schema, dest_table)
-- auto_insert(source_table, dest_table)
-------------------------------------------------------------------------------
-- The auto_insert procedure inserts all data from source_table into dest_table
-- by means of an automatically generated INSERT statement covering all columns
-- common to both tables.
--
-- If source_schema and dest_schema are not specified they default to the
-- current schema.
-------------------------------------------------------------------------------

CREATE FUNCTION auto_insert(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
BEGIN
    PERFORM x_insert_checks(source_schema, source_table, dest_schema, dest_table);
    EXECUTE x_build_insert(source_schema, source_table, dest_schema, dest_table);
END;
$$;

CREATE FUNCTION auto_insert(
    source_table name,
    dest_table name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_insert(current_schema, source_table, current_schema, dest_table);
$$;

GRANT EXECUTE ON FUNCTION
    auto_insert(name, name, name, name),
    auto_insert(name, name)
    TO utils_merge_user;

GRANT EXECUTE ON FUNCTION
    auto_insert(name, name, name, name),
    auto_insert(name, name)
    TO utils_merge_admin WITH GRANT OPTION;

COMMENT ON FUNCTION auto_insert(name, name, name, name)
    IS 'Automatically inserts data from source_table into dest_table';
COMMENT ON FUNCTION auto_insert(name, name)
    IS 'Automatically inserts data from source_table into dest_table';

-- auto_merge(source_schema, source_table, dest_schema, dest_table, dest_key)
-- auto_merge(source_schema, source_table, dest_schema, dest_table)
-- auto_merge(source_table, dest_table, dest_key)
-- auto_merge(source_table, dest_table)
-------------------------------------------------------------------------------
-- The auto_merge procedure performs an "upsert", or combined insert and update
-- of all data from source_table into dest_table by means of an automatically
-- generated queried insert/update statement.
--
-- The dest_key parameter specifies the name of the unique key to use for
-- identifying rows in the destination table. If specified, it must be the name
-- of a unique key or primary key of the destination table which covers columns
-- which exist in both the source and destination tables. If omitted, it
-- defaults to the name of the primary key of the destination table.
--
-- If source_schema and dest_schema are not specified they default to the
-- current schema.
-------------------------------------------------------------------------------

CREATE FUNCTION auto_merge(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_key name
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
BEGIN
    PERFORM x_merge_checks(source_schema, source_table, dest_schema, dest_table, dest_key);
    EXECUTE x_build_merge(source_schema, source_table, dest_schema, dest_table, dest_key);
END;
$$;

CREATE FUNCTION auto_merge(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_merge(source_schema, source_table, dest_schema, dest_table, (
            SELECT conname
            FROM pg_catalog.pg_constraint
            WHERE conrelid = table_oid(dest_schema, dest_table)
            AND contype = 'p'
        ));
$$;

CREATE FUNCTION auto_merge(
    source_table name,
    dest_table name,
    dest_key name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_merge(current_schema, source_table, current_schema, dest_table, dest_key);
$$;

CREATE FUNCTION auto_merge(
    source_table name,
    dest_table name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_merge(current_schema, source_table, current_schema, dest_table);
$$;

GRANT EXECUTE ON FUNCTION
    auto_merge(name, name, name, name, name),
    auto_merge(name, name, name, name),
    auto_merge(name, name, name),
    auto_merge(name, name)
    TO utils_merge_user;

GRANT EXECUTE ON FUNCTION
    auto_merge(name, name, name, name, name),
    auto_merge(name, name, name, name),
    auto_merge(name, name, name),
    auto_merge(name, name)
    TO utils_merge_admin WITH GRANT OPTION;

COMMENT ON FUNCTION auto_merge(name, name, name, name, name)
    IS 'Automatically inserts/updates ("upserts") data from source_table into dest_table based on dest_key';
COMMENT ON FUNCTION auto_merge(name, name, name, name)
    IS 'Automatically inserts/updates ("upserts") data from source_table into dest_table based on dest_key';
COMMENT ON FUNCTION auto_merge(name, name, name)
    IS 'Automatically inserts/updates ("upserts") data from source_table into dest_table based on dest_key';
COMMENT ON FUNCTION auto_merge(name, name)
    IS 'Automatically inserts/updates ("upserts") data from source_table into dest_table based on dest_key';

-- auto_delete(source_schema, source_table, dest_schema, dest_table, dest_key)
-- auto_delete(source_schema, source_table, dest_schema, dest_table)
-- auto_delete(source_table, dest_table, dest_key)
-- auto_delete(source_table, dest_table)
-------------------------------------------------------------------------------
-- The auto_delete procedure deletes rows from dest_table that do not exist
-- in source_table. This procedure is intended to be used after the auto_merge
-- procedure has been used to upsert from source to dest.
--
-- The dest_key parameter specifies the name of the unique key to use for
-- identifying rows in the destination table. If specified, it must be the name
-- of a unique key or primary key which covers columns which exist in both the
-- source and destination tables. If omitted, it defaults to the name of the
-- primary key of the destination table.
--
-- If source_schema and dest_schema are not specified they default to the
-- current schema.
-------------------------------------------------------------------------------

CREATE FUNCTION auto_delete(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_key name
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
BEGIN
    PERFORM x_merge_checks(source_schema, source_table, dest_schema, dest_table, dest_key);
    EXECUTE x_build_delete(source_schema, source_table, dest_schema, dest_table, dest_key);
END;
$$;

CREATE FUNCTION auto_delete(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_delete(source_schema, source_table, dest_schema, dest_table, (
            SELECT conname
            FROM pg_catalog.pg_constraint
            WHERE conrelid = table_oid(dest_schema, dest_table)
            AND contype = 'p'
        ));
$$;

CREATE FUNCTION auto_delete(
    source_table name,
    dest_table name,
    dest_key name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_delete(current_schema, source_table, current_schema, dest_table, dest_key);
$$;

CREATE FUNCTION auto_delete(
    source_table name,
    dest_table name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_delete(current_schema, source_table, current_schema, dest_table);
$$;

GRANT EXECUTE ON FUNCTION
    auto_delete(name, name, name, name, name),
    auto_delete(name, name, name, name),
    auto_delete(name, name, name),
    auto_delete(name, name)
    TO utils_merge_user;

GRANT EXECUTE ON FUNCTION
    auto_delete(name, name, name, name, name),
    auto_delete(name, name, name, name),
    auto_delete(name, name, name),
    auto_delete(name, name)
    TO utils_merge_admin WITH GRANT OPTION;

COMMENT ON FUNCTION auto_delete(name, name, name, name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';
COMMENT ON FUNCTION auto_delete(name, name, name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';
COMMENT ON FUNCTION auto_delete(name, name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';
COMMENT ON FUNCTION auto_delete(name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';

-- vim: set et sw=4 sts=4:
