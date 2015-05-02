-------------------------------------------------------------------------------
-- MERGE UTILITIES
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
-- The following routines permit easy construction of MERGE-like instructions
-- for the purpose of bulk upserts from a source table to a similarly
-- structured destination table.
-------------------------------------------------------------------------------

-- Complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION merge" to load this file. \quit

-- _build_insert(source_schema, source_table, dest_schema, dest_table)
-- _build_merge(source_schema, source_table, dest_schema, dest_table, dest_key)
-- _build_delete(source_schema, source_table, dest_schema, dest_table, dest_key)
-- _merge_checks(source_schema, source_table, dest_schema, dest_table, dest_key)
-------------------------------------------------------------------------------
-- These functions are effectively private utility subroutines for the
-- procedures defined below. They simply generate snippets of SQL given a set
-- of input parameters.
-------------------------------------------------------------------------------

-- Build an INSERT..SELECT from source_oid to dest_oid

CREATE FUNCTION _build_insert(source_oid oid, dest_oid oid)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    cols text DEFAULT '';
BEGIN
    SELECT string_agg(quote_ident(t.attname), ',')
    INTO STRICT cols
    FROM
        pg_catalog.pg_attribute s
        JOIN pg_catalog.pg_attribute t
            ON s.attname = t.attname
    WHERE
        s.attrelid = source_oid
        AND t.attrelid = dest_oid
        AND t.attnum > 0
        AND NOT t.attisdropped;

    RETURN format(
        $sql$
        INSERT INTO %s (%s)
        SELECT %s FROM %s
        $sql$,

        dest_oid::regclass, cols,
        cols, source_oid::regclass
    );
END;
$$;

-- Build an UPDATE with a RETURNING clause from source_oid to dest_oid, joining
-- on the unique constraint named by dest_key. This is used by auto_merge

CREATE FUNCTION _build_update(source_oid oid, dest_oid oid, dest_key name)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    set_cols text DEFAULT '';
    where_cols text DEFAULT '';
    return_cols text DEFAULT '';
BEGIN
    SELECT
        string_agg(CASE WHEN NOT (ARRAY [t.attnum] <@ c.conkey) THEN format('%I = src.%I', t.attname, t.attname) END, ',') AS set_cols,
        string_agg(CASE WHEN ARRAY [t.attnum] <@ c.conkey THEN format('src.%I', t.attname) END, ',') AS return_cols,
        string_agg(CASE WHEN ARRAY [t.attnum] <@ c.conkey THEN format('src.%I = dest.%I', t.attname, t.attname) END, ' AND ') AS where_cols
    INTO STRICT
        set_cols, return_cols, where_cols
    FROM
        pg_catalog.pg_attribute s
        JOIN pg_catalog.pg_attribute t
            ON s.attname = t.attname
        JOIN pg_catalog.pg_constraint c
            ON c.conrelid = t.attrelid
    WHERE
        s.attrelid = source_oid
        AND t.attrelid = dest_oid
        AND t.attnum > 0
        AND NOT t.attisdropped
        AND c.contype IN ('p', 'u')
        -- XXX what about connamespace?
        AND c.conname = dest_key;

    RETURN format(
        $sql$
        UPDATE %s AS dest SET %s
        FROM %s AS src WHERE %s
        RETURNING %s
        $sql$,

        dest_oid::regclass, set_cols,
        source_oid::regclass, where_cols,
        return_cols
    );
END;
$$;

-- Build a DELETE targetting dest_oid which excludes keys still present in
-- source_oid (keys defined by dest_key); this is used by auto_delete

CREATE FUNCTION _build_delete(source_oid oid, dest_oid oid, dest_key name)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    key_cols text DEFAULT '';
BEGIN
    SELECT string_agg(quote_ident(t.attname), ',')
    INTO key_cols
    FROM
        pg_catalog.pg_attribute t
        JOIN pg_catalog.pg_constraint c
            ON c.conrelid = t.attrelid
    WHERE
        t.attrelid = dest_oid
        AND t.attnum > 0
        AND NOT t.attisdropped
        AND c.contype IN ('p', 'u')
        -- XXX what about connamespace?
        AND c.conname = dest_key
        AND ARRAY [t.attnum] <@ c.conkey;

    RETURN format(
        $sql$
        DELETE FROM %s WHERE ROW (%s) IN (
            SELECT %s FROM %s
            EXCEPT
            SELECT %s FROM %s
        )
        $sql$,

        dest_oid::regclass, key_cols,
        key_cols, dest_oid::regclass,
        key_cols, source_oid::regclass
    );
END;
$$;

-- Build a statement for merging records from source_oid to dest_oid, keyed
-- by dest_key. This uses various functions above depending on whether the
-- target contains non-key attributes or not

CREATE FUNCTION _build_merge(source_oid oid, dest_oid oid, dest_key name)
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
            t.attrelid = dest_oid
            AND t.attnum > 0
            AND NOT t.attisdropped
            AND c.contype IN ('p', 'u')
            -- XXX what about connamespace?
            AND c.conname = dest_key
            AND ARRAY [t.attnum] <@ c.conkey
    LOOP
        key_cols := key_cols || format(',%I', r.attname);
    END LOOP;
    key_cols := substring(key_cols from 2);

    RETURN format(
        $sql$
        WITH upsert AS (
            %s
        )
        %s WHERE ROW (%s) NOT IN (
            SELECT %s
            FROM upsert
        )
        $sql$,

        _build_update(source_oid, dest_oid, dest_key),
        _build_insert(source_oid, dest_oid),
        key_cols, key_cols
    );
END;
$$;

CREATE FUNCTION _insert_checks(source_oid oid, dest_oid oid)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
BEGIN
    IF source_oid = dest_oid THEN
        RAISE EXCEPTION USING
            ERRCODE = 'UTM01',
            MESSAGE = 'Source and destination tables cannot be the same',
            TABLE = source_oid;
    END IF;
END;
$$;

CREATE FUNCTION _merge_checks(source_oid oid, dest_oid oid, dest_key name)
    RETURNS void
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    r record;
BEGIN
    PERFORM _insert_checks(source_oid, dest_oid);

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
            s.attrelid = source_oid
            AND t.attrelid = dest_oid
            AND t.attnum > 0
            AND NOT t.attisdropped
            AND c.contype IN ('p', 'u')
            -- XXX what about connamespace?
            AND c.conname = dest_key
            AND ARRAY [t.attnum] <@ c.conkey
            AND s.attname IS NULL
    LOOP
        RAISE EXCEPTION USING
            ERRCODE = 'UTM02',
            MESSAGE = format(
                'All fields of constraint %I must exist in the source and target tables', dest_key),
            TABLE = dest_oid;
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
DECLARE
    source_oid regclass;
    dest_oid regclass;
BEGIN
    source_oid := (
        quote_ident(source_schema) || '.' || quote_ident(source_table)
    )::regclass;

    dest_oid := (
        quote_ident(dest_schema) || '.' || quote_ident(dest_table)
    )::regclass;

    PERFORM _insert_checks(source_oid, dest_oid);
    EXECUTE _build_insert(source_oid, dest_oid);
END;
$$;

CREATE FUNCTION auto_insert(source_table name, dest_table name)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT auto_insert(current_schema, source_table, current_schema, dest_table);
$$;

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
DECLARE
    source_oid regclass;
    dest_oid regclass;
BEGIN
    source_oid := (
        quote_ident(source_schema) || '.' || quote_ident(source_table)
    )::regclass;

    dest_oid := (
        quote_ident(dest_schema) || '.' || quote_ident(dest_table)
    )::regclass;

    PERFORM _merge_checks(source_oid, dest_oid, dest_key);
    EXECUTE _build_merge(source_oid, dest_oid, dest_key);
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
            WHERE conrelid = (quote_ident(dest_schema) || '.' || quote_ident(dest_table))::regclass
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
DECLARE
    source_oid regclass;
    dest_oid regclass;
BEGIN
    source_oid := (
        quote_ident(source_schema) || '.' || quote_ident(source_table)
    )::regclass;

    dest_oid := (
        quote_ident(dest_schema) || '.' || quote_ident(dest_table)
    )::regclass;

    PERFORM _merge_checks(source_oid, dest_oid, dest_key);
    EXECUTE _build_delete(source_oid, dest_oid, dest_key);
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
            WHERE conrelid = (quote_ident(dest_schema) || '.' || quote_ident(dest_table))::regclass
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

COMMENT ON FUNCTION auto_delete(name, name, name, name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';
COMMENT ON FUNCTION auto_delete(name, name, name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';
COMMENT ON FUNCTION auto_delete(name, name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';
COMMENT ON FUNCTION auto_delete(name, name)
    IS 'Automatically removes data from dest_table that doesn''t exist in source_table, based on dest_key';

-- vim: set et sw=4 sts=4:
