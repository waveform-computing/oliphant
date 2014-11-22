-------------------------------------------------------------------------------
-- HISTORY FRAMEWORK
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
-- The following code is adapted from a Usenet posting, discussing methods of
-- tracking history via triggers:
--
-- http://groups.google.com/group/comp.databases.ibm-db2/msg/e84aeb1f6ac87e6c
--
-- Routines are provided for creating a table which will store the history of
-- a "master" table, and for creating triggers that will keep the history
-- populated as rows are manipulated in the master. Routines are also provided
-- for creating views providing commonly requested transformations of the
-- history such as "what changed when" and "snapshots over constant periods".
-------------------------------------------------------------------------------


-- ROLES
-------------------------------------------------------------------------------
-- The following roles grant usage and administrative rights to the objects
-- created by this module.
-------------------------------------------------------------------------------

CREATE ROLE UTILS_HISTORY_USER;
CREATE ROLE UTILS_HISTORY_ADMIN;

--GRANT UTILS_HISTORY_USER TO UTILS_USER;
GRANT UTILS_HISTORY_USER TO UTILS_HISTORY_ADMIN WITH ADMIN OPTION;
--GRANT UTILS_HISTORY_ADMIN TO UTILS_ADMIN WITH ADMIN OPTION;

-- SQLSTATES
-------------------------------------------------------------------------------
-- The following variables define the set of SQLSTATEs raised by the procedures
-- and functions in this module.
-------------------------------------------------------------------------------

--CREATE VARIABLE HISTORY_KEY_FIELDS_STATE CHAR(5) CONSTANT '90004';
--CREATE VARIABLE HISTORY_NO_PK_STATE CHAR(5) CONSTANT '90005';
--CREATE VARIABLE HISTORY_UPDATE_PK_STATE CHAR(5) CONSTANT '90006';
--
--GRANT READ ON VARIABLE HISTORY_KEY_FIELDS_STATE TO ROLE UTILS_HISTORY_USER;
--GRANT READ ON VARIABLE HISTORY_NO_PK_STATE TO ROLE UTILS_HISTORY_USER;
--GRANT READ ON VARIABLE HISTORY_UPDATE_PK_STATE TO ROLE UTILS_HISTORY_USER;
--GRANT READ ON VARIABLE HISTORY_KEY_FIELDS_STATE TO ROLE UTILS_HISTORY_ADMIN WITH GRANT OPTION;
--GRANT READ ON VARIABLE HISTORY_NO_PK_STATE TO ROLE UTILS_HISTORY_ADMIN WITH GRANT OPTION;
--GRANT READ ON VARIABLE HISTORY_UPDATE_PK_STATE TO ROLE UTILS_HISTORY_ADMIN WITH GRANT OPTION;
--
--COMMENT ON VARIABLE HISTORY_KEY_FIELDS_STATE
--    IS 'The SQLSTATE raised when a history sub-routine is called with something other than ''Y'' or ''N'' as the KEY_FIELDS parameter';
--
--COMMENT ON VARIABLE HISTORY_NO_PK_STATE
--    IS 'The SQLSTATE raised when an attempt is made to create a history table for a table without a primary key';
--
--COMMENT ON VARIABLE HISTORY_UPDATE_PK_STATE
--    IS 'The SQLSTATE raised when an attempt is made to update a primary key''s value in a table with an associated history table';

-- X_HISTORY_PERIODLEN(RESOLUTION)
-- X_HISTORY_PERIODSTEP(RESOLUTION)
-- X_HISTORY_PERIODSTEP(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EFFNAME(RESOLUTION)
-- X_HISTORY_EFFNAME(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EXPNAME(RESOLUTION)
-- X_HISTORY_EXPNAME(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EFFDEFAULT(RESOLUTION)
-- X_HISTORY_EFFDEFAULT(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EXPDEFAULT(RESOLUTION)
-- X_HISTORY_EXPDEFAULT(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_PERIODSTART(RESOLUTION, EXPRESSION)
-- X_HISTORY_PERIODEND(RESOLUTION, EXPRESSION)
-- X_HISTORY_EFFNEXT(RESOLUTION, OFFSET)
-- X_HISTORY_EXPPRIOR(RESOLUTION, OFFSET)
-- X_HISTORY_INSERT(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION, OFFSET)
-- X_HISTORY_EXPIRE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION, OFFSET)
-- X_HISTORY_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION)
-- X_HISTORY_UPDATE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION)
-- X_HISTORY_CHECK(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION)
-- X_HISTORY_CHANGES(SOURCE_SCHEMA, SOURCE_TABLE, RESOLUTION)
-- X_HISTORY_SNAPSHOTS(SOURCE_SCHEMA, SOURCE_TABLE, RESOLUTION)
-- X_HISTORY_UPDATE_FIELDS(SOURCE_SCHEMA, SOURCE_TABLE, KEY_FIELDS)
-- X_HISTORY_UPDATE_WHEN(SOURCE_SCHEMA, SOURCE_TABLE, KEY_FIELDS)
-------------------------------------------------------------------------------
-- These functions are effectively private utility subroutines for the
-- procedures defined below. They simply generate snippets of SQL given a set
-- of input parameters.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION x_history_periodlen(resolution VARCHAR(12))
    RETURNS INTERVAL
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE resolution
        WHEN 'quarter' THEN interval '3 months'
        WHEN 'millennium' THEN interval '1000 years'
        ELSE CAST('1 ' || resolution AS INTERVAL)
    END);
$$;

CREATE OR REPLACE FUNCTION x_history_periodstep(resolution VARCHAR(12))
    RETURNS INTERVAL
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
        THEN INTERVAL '1 day'
        ELSE INTERVAL '1 microsecond'
    END);
$$;

CREATE OR REPLACE FUNCTION x_history_periodstep(source_schema NAME, source_table NAME)
    RETURNS INTERVAL
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (CASE (
            SELECT format_type(atttypid, NULL)
            FROM pg_catalog.pg_attribute
            WHERE
                attrelid = CAST(
                    quote_ident(source_schema) || '.' || quote_ident(source_table)
                    AS regclass)
                AND attnum = 1
            )
        WHEN 'timestamp without time zone' THEN INTERVAL '1 microsecond'
        WHEN 'date' THEN INTERVAL '1 day'
    END);
$$;

CREATE OR REPLACE FUNCTION x_history_effname(resolution VARCHAR(12))
    RETURNS NAME
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CAST('effective' AS name));
$$;

CREATE OR REPLACE FUNCTION x_history_effname(source_schema NAME, source_table NAME)
    RETURNS NAME
    LANGUAGE SQL
    STABLE
AS $$
    SELECT attname
    FROM pg_catalog.pg_attribute
    WHERE
        attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND attnum = 1;
$$;

CREATE OR REPLACE FUNCTION x_history_expname(resolution VARCHAR(12))
    RETURNS NAME
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CAST('expiry' AS NAME));
$$;

CREATE OR REPLACE FUNCTION x_history_expname(source_schema NAME, source_table NAME)
    RETURNS NAME
    LANGUAGE SQL
    STABLE
AS $$
    SELECT attname
    FROM pg_catalog.pg_attribute
    WHERE
        attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND attnum = 2;
$$;

CREATE OR REPLACE FUNCTION x_history_effdefault(resolution VARCHAR(12))
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
            THEN 'current_date'
            ELSE 'current_timestamp'
        END);
$$;

CREATE OR REPLACE FUNCTION x_history_effdefault(source_schema NAME, source_table NAME)
    RETURNS TEXT
    LANGUAGE SQL
    STABLE
AS $$
    SELECT d.adsrc
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = a.attrelid
            AND d.adnum = a.attnum
    WHERE
        a.attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND a.attnum = 1;
$$;

CREATE OR REPLACE FUNCTION x_history_expdefault(resolution VARCHAR(12))
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
            THEN 'DATE ''9999-12-31'''
            ELSE 'TIMESTAMP ''9999-12-31 23:59:59.999999'''
        END);
$$;

CREATE OR REPLACE FUNCTION x_history_expdefault(source_schema name, source_table name)
    RETURNS text
    LANGUAGE SQL
    STABLE
AS $$
    SELECT d.adsrc
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = a.attrelid
            AND d.adnum = a.attnum
    WHERE
        a.attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND a.attnum = 2;
$$;

CREATE OR REPLACE FUNCTION x_history_periodstart(resolution VARCHAR(12), expression TEXT)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        'date_trunc(' || quote_literal(resolution) || ', ' || expression || ')'
    );
$$;

CREATE OR REPLACE FUNCTION x_history_periodend(resolution VARCHAR(12), expression TEXT)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        'date_trunc(' || quote_literal(resolution) || ', ' || expression || ') + '
        || 'INTERVAL ' || quote_literal(x_history_periodlen(resolution)) || ' - '
        || 'INTERVAL ' || quote_literal(x_history_periodstep(resolution))
    );
$$;

CREATE OR REPLACE FUNCTION x_history_effnext(resolution VARCHAR(12), shift INTERVAL)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        x_history_periodstart(
            resolution, x_history_effdefault(resolution)
            || CASE WHEN shift IS NOT NULL
                THEN ' + INTERVAL ' || quote_literal(shift)
                ELSE ''
            END)
    );
$$;

CREATE OR REPLACE FUNCTION x_history_expprior(resolution VARCHAR(12), shift INTERVAL)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        x_history_periodend(
            resolution, x_history_effdefault(resolution)
            || ' - INTERVAL ' || quote_literal(x_history_periodlen(resolution))
            || CASE WHEN shift IS NOT NULL
                THEN ' + INTERVAL ' || quote_literal(shift)
                ELSE ''
            END)
    );
$$;

CREATE OR REPLACE FUNCTION x_history_insert(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    insert_stmt TEXT DEFAULT '';
    values_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    insert_stmt := 'INSERT INTO ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '(';
    values_stmt = ' VALUES (';
    insert_stmt := insert_stmt || quote_ident(x_history_effname(dest_schema, dest_table));
    values_stmt := values_stmt || x_history_effnext(resolution, shift);
    FOR r IN
        SELECT attname
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
        ORDER BY attnum
    LOOP
        insert_stmt := insert_stmt || ',' || quote_ident(r.attname);
        values_stmt := values_stmt || ',NEW.' || quote_ident(r.attname);
    END LOOP;
    insert_stmt := insert_stmt || ')';
    values_stmt := values_stmt || ')';
    RETURN insert_stmt || values_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_expire(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    update_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    update_stmt := 'UPDATE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || ' SET '   || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expprior(resolution, shift)
        || ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
    LOOP
        update_stmt := update_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN update_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_update(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    update_stmt TEXT DEFAULT '';
    set_stmt TEXT DEFAULT '';
    where_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    update_stmt := 'UPDATE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' ';
    where_stmt := ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname, ARRAY [att.attnum] <@ con.conkey AS iskey
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
    LOOP
        IF r.iskey THEN
            where_stmt := where_stmt
                || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
        ELSE
            set_stmt := set_stmt
                || ', ' || quote_ident(r.attname) || ' = NEW.' || quote_ident(r.attname);
        END IF;
    END LOOP;
    set_stmt = 'SET' || substring(set_stmt from 2);
    RETURN update_stmt || set_stmt || where_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_delete(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    delete_stmt TEXT DEFAULT '';
    where_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    delete_stmt = 'DELETE FROM ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table);
    where_stmt = ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        where_stmt := where_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN delete_stmt || where_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_check(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt TEXT DEFAULT '';
    where_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    select_stmt :=
        'SELECT ' || x_history_periodend(resolution, x_history_effname(dest_schema, dest_table))
        || ' FROM ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table);
    where_stmt :=
        ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        where_stmt := where_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN select_stmt || where_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_changes(
    source_schema NAME,
    source_table NAME
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt TEXT DEFAULT '';
    from_stmt TEXT DEFAULT '';
    insert_test TEXT DEFAULT '';
    update_test TEXT DEFAULT '';
    delete_test TEXT DEFAULT '';
    r RECORD;
BEGIN
    from_stmt :=
        ' FROM ' || quote_ident('old_' || source_table) || ' AS old'
        || ' FULL JOIN ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' AS new'
        || ' ON new.' || x_history_effname(source_schema, source_table) || ' - ' || x_history_periodstep(source_schema, source_table)
        || ' BETWEEN old.' || x_history_effname(source_schema, source_table)
        || ' AND old.' || x_history_expname(source_schema, source_table);
    FOR r IN
        SELECT att.attname, ARRAY [att.attnum] <@ con.conkey AS iskey
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
    LOOP
        select_stmt := select_stmt
            || ', old.' || quote_ident(r.attname) || ' AS ' || quote_ident('old_' || r.attname)
            || ', new.' || quote_ident(r.attname) || ' AS ' || quote_ident('new_' || r.attname);
        IF r.iskey THEN
            from_stmt := from_stmt
                || ' AND old.' || quote_ident(r.attname) || ' = new.' || quote_ident(r.attname);
            insert_test := insert_test
                || 'AND old.' || quote_ident(r.attname) || ' IS NULL '
                || 'AND new.' || quote_ident(r.attname) || ' IS NOT NULL ';
            update_test := update_test
                || 'AND old.' || quote_ident(r.attname) || ' IS NOT NULL '
                || 'AND new.' || quote_ident(r.attname) || ' IS NOT NULL ';
            delete_test := delete_test
                || 'AND old.' || quote_ident(r.attname) || ' IS NOT NULL '
                || 'AND new.' || quote_ident(r.attname) || ' IS NULL ';
        END IF;
    END LOOP;
    select_stmt :=
        'SELECT'
        || ' coalesce(new.'
            || quote_ident(x_history_effname(source_schema, source_table)) || ', old.'
            || quote_ident(x_history_expname(source_schema, source_table)) || ' + ' || x_history_periodstep(source_schema, source_table) || ') AS changed'
        || ', CAST(CASE '
            || 'WHEN' || substring(insert_test from 4) || 'THEN ''INSERT'' '
            || 'WHEN' || substring(update_test from 4) || 'THEN ''UPDATE'' '
            || 'WHEN' || substring(delete_test from 4) || 'THEN ''DELETE'' '
            || 'ELSE ''ERROR'' END AS CHAR) AS change'
        || SELECT_STMT;
    RETURN
        'WITH ' || quote_ident('old_' || source_table) || ' AS ('
        || '    SELECT *'
        || '    FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table)
        || '    WHERE ' || x_history_expname(source_schema, source_table) || ' < ' || x_history_expdefault(source_schema, source_table)
        || ') '
        || select_stmt
        || from_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_snapshots(
    source_schema NAME,
    source_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    select_stmt :=
        'WITH range(at) AS ('
        || '    SELECT min(' || quote_ident(x_history_effname(source_schema, source_table)) || ')'
        || '    FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table)
        || '    UNION ALL'
        || '    SELECT at + ' || x_history_periodlen(resolution)
        || '    FROM range'
        || '    WHERE at <= ' || x_history_effdefault(resolution)
        || ') '
        || 'SELECT ' || x_history_periodend(resolution, 'r.at') || ' AS snapshot';
    FOR r IN
        SELECT attname
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 2
        ORDER BY attnum
    LOOP
        select_stmt := select_stmt
            || ', h.' || quote_ident(r.attname);
    END LOOP;
    RETURN select_stmt
        || ' FROM range r JOIN ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' H'
        || ' ON r.at BETWEEN h.' || quote_ident(x_history_effname(source_schema, source_table))
        || ' AND h.' || quote_ident(x_history_expname(source_schema, source_table));
END;
$$;

CREATE OR REPLACE FUNCTION x_history_update_fields(
    source_schema NAME,
    source_table NAME,
    key_fields BOOLEAN
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    result TEXT DEFAULT '';
    r RECORD;
BEGIN
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND (
                (key_fields AND ARRAY [att.attnum] <@ con.conkey) OR
                NOT (key_fields OR ARRAY [att.attnum] <@ con.conkey)
            )
        ORDER BY att.attnum
    LOOP
        result := result || ', ' || quote_ident(r.attname);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_update_when(
    source_schema NAME,
    source_table NAME,
    key_fields BOOLEAN
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    result TEXT DEFAULT '';
    r RECORD;
BEGIN
    FOR r IN
        SELECT att.attname, att.attnotnull
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND (
                (key_fields AND ARRAY [att.attnum] <@ con.conkey) OR
                NOT (key_fields OR ARRAY [att.attnum] <@ con.conkey)
            )
        ORDER BY att.attnum
    LOOP
        result := result
            || ' OR old.' || quote_ident(r.attname) || ' <> new.' || quote_ident(r.attname);
        IF NOT r.attnotnull THEN
            result := result
                || ' OR (old.' || quote_ident(r.attname) || ' IS NULL AND new.' || quote_ident(r.attname) || ' IS NOT NULL)'
                || ' OR (new.' || quote_ident(r.attname) || ' IS NULL AND old.' || quote_ident(r.attname) || ' IS NOT NULL)';
        END IF;
    END LOOP;
    RETURN substring(result from 5);
END;
$$;

-- create_history_table(source_schema, source_table, dest_schema, dest_table, dest_tbspace, resolution)
-- create_history_table(source_table, dest_table, dest_tbspace, resolution)
-- create_history_table(source_table, dest_table, resolution)
-- create_history_table(source_table, resolution)
-------------------------------------------------------------------------------
-- The create_history_table procedure creates, from a template table specified
-- by source_schema and source_table, another table named by dest_schema and
-- dest_table designed to hold a representation of the source table's content
-- over time.  Specifically, the destination table has the same structure as
-- source table, but with two additional columns named "effective" and "expiry"
-- which occur before all other original columns. The primary key of the source
-- table, in combination with "effective" will form the primary key of the
-- destination table, and a unique index involving the primary key and the
-- "expiry" column will also be created as this provides better performance of
-- the triggers used to maintain the destination table.
--
-- The dest_tbspace parameter identifies the tablespace used to store the new
-- table's data. If dest_tbspace is not specified, it defaults to the
-- tablespace of the source table. If dest_table is not specified it defaults
-- to the value of source_table with "_history" as a suffix. If dest_schema and
-- source_schema are not specified they default to the current schema.
--
-- The resolution parameter determines the smallest unit of time that a history
-- record can cover. See the create_history_trigger documentation for a list of
-- the possible values.
--
-- All SELECT and CONTROL authorities present on the source table will be
-- copied to the destination table. However, INSERT, UPDATE and DELETE
-- authorities are excluded as these operations should only ever be performed
-- by the history maintenance triggers themselves.
--
-- If the specified table already exists, this procedure will replace it,
-- potentially losing all its content. If the existing history data is
-- important to you, make sure you back it up before executing this procedure.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_history_table(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    dest_tbspace NAME,
    resolution VARCHAR(12)
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    key_name NAME DEFAULT '';
    key_cols TEXT DEFAULT '';
    ddl TEXT DEFAULT '';
    r RECORD;
BEGIN
    --CALL ASSERT_TABLE_EXISTS(SOURCE_SCHEMA, SOURCE_TABLE);
    -- Check the source table has a primary key
    --IF (SELECT COALESCE(KEYCOLUMNS, 0)
    --    FROM SYSCAT.TABLES
    --    WHERE TABSCHEMA = SOURCE_SCHEMA
    --    AND TABNAME = SOURCE_TABLE) = 0 THEN
    --        CALL SIGNAL_STATE(HISTORY_NO_PK_STATE, 'Source table must have a primary key');
    --END IF;
    -- Drop any existing table with the same name as the destination table
    FOR r IN
        SELECT
            'DROP TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) AS drop_cmd
        FROM pg_catalog.pg_class
        WHERE oid = CAST(quote_ident(dest_schema) || '.' || quote_ident(dest_table) AS regclass)
    LOOP
        EXECUTE r.drop_cmd;
    END LOOP;
    -- Calculate comma-separated lists of key columns in the order they are
    -- declared in the primary key (for generation of constraints later)
    FOR r IN
        WITH subscripts(i) AS (
            SELECT generate_subscripts(conkey, 1)
            FROM pg_catalog.pg_constraint
            WHERE
                conrelid = CAST(
                    quote_ident(source_schema) || '.' || quote_ident(source_table)
                    AS regclass)
                AND contype = 'p'
        )
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
            JOIN subscripts sub
                ON att.attnum = con.conkey[sub.i]
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
        ORDER BY sub.i
    LOOP
        key_cols := key_cols
            || quote_ident(r.attname) || ',';
    END LOOP;
    -- Create the history table based on the source table
    ddl :=
        'CREATE TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' AS '
        || '('
        ||     'SELECT '
        ||          x_history_effdefault(resolution) || ' AS ' || quote_ident(x_history_effname(resolution)) || ','
        ||          x_history_expdefault(resolution) || ' AS ' || quote_ident(x_history_expname(resolution)) || ','
        ||         't.* '
        ||     'FROM '
        ||          quote_ident(source_schema) || '.' || quote_ident(source_table) || ' AS t'
        || ')'
        || 'WITH NO DATA ';
    IF dest_tbspace IS NOT NULL THEN
        ddl := ddl || 'TABLESPACE ' || quote_ident(dest_tbspace);
    END IF;
    EXECUTE ddl;
    -- Copy NOT NULL constraints from the source table to the history table
    ddl := '';
    FOR r IN
        SELECT attname
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnotnull
            AND attnum > 0
    LOOP
        ddl :=
            'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
            || ' ALTER COLUMN ' || quote_ident(r.attname) || ' SET NOT NULL';
        EXECUTE ddl;
    END LOOP;
    -- Copy CHECK and EXCLUDE constraints from the source table to the history
    -- table. Note that we do not copy FOREIGN KEY constraints as there's no
    -- good method of matching a parent record in a historized table.
    ddl := '';
    FOR r IN
        SELECT pg_get_constraintdef(oid) AS ddl
        FROM pg_catalog.pg_constraint
        WHERE
            conrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND contype IN ('c', 'x')
    LOOP
        ddl :=
            'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
            || ' ADD ' || r.ddl;
    END LOOP;
    -- Create two unique constraints, both based on the source table's primary
    -- key, plus the EFFECTIVE and EXPIRY fields respectively. Use INCLUDE for
    -- additional small fields in the EFFECTIVE index. The columns included are
    -- the same as those included in the primary key of the source table.
    -- TODO tablespaces...
    key_name := quote_ident(dest_table || '_pkey');
    ddl :=
        'CREATE UNIQUE INDEX '
        || key_name || ' '
        || 'ON ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || '(' || key_cols || quote_ident(x_history_effname(resolution))
        || ')';
    EXECUTE ddl;
    ddl :=
        'CREATE UNIQUE INDEX '
        || quote_ident(dest_table || '_ix1') || ' '
        || 'ON ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || '(' || key_cols || quote_ident(x_history_expname(resolution))
        || ')';
    EXECUTE ddl;
    -- Create additional indexes that are useful for performance purposes
    ddl :=
        'CREATE INDEX '
        || quote_ident(dest_table || '_ix2') || ' '
        || 'ON ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || '(' || quote_ident(x_history_effname(resolution))
        || ',' || quote_ident(x_history_expname(resolution))
        || ')';
    EXECUTE ddl;
    -- Create a primary key with the same fields as the EFFECTIVE index defined
    -- above.
    ddl :=
        'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' '
        || 'ADD PRIMARY KEY USING INDEX ' || key_name || ', '
        || 'ADD CHECK (' || quote_ident(x_history_effname(resolution)) || ' <= ' || quote_ident(x_history_expname(resolution)) || '), '
        || 'ALTER COLUMN ' || quote_ident(x_history_effname(resolution)) || ' SET DEFAULT ' || x_history_effdefault(resolution) || ', '
        || 'ALTER COLUMN ' || quote_ident(x_history_expname(resolution)) || ' SET DEFAULT ' || x_history_expdefault(resolution);
    EXECUTE ddl;
    -- TODO authorizations; needs auth.sql first
    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    ddl :=
        'COMMENT ON TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || ' IS ' || quote_literal('History table which tracks the content of @' || source_schema || '.' || source_table);
    EXECUTE ddl;
    ddl :=
        'COMMENT ON COLUMN ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '.' || quote_ident(x_history_effname(resolution))
        || ' IS ' || quote_literal('The date/timestamp from which this row was present in the source table');
    EXECUTE ddl;
    ddl :=
        'COMMENT ON COLUMN ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '.' || quote_ident(x_history_expname(resolution))
        || ' IS ' || quote_literal('The date/timestamp until which this row was present in the source table (rows with 9999-12-31 currently exist in the source table)');
    EXECUTE ddl;
    FOR r IN
        SELECT attname, col_description(
            CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass), attnum) AS attdesc
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 0
    LOOP
        IF r.attdesc IS NOT NULL THEN
            ddl :=
                'COMMENT ON COLUMN ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '.' || quote_ident(r.attname)
                || ' IS ' || quote_literal(r.attdesc);
            EXECUTE ddl;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION create_history_table(
    source_table NAME,
    dest_table NAME,
    dest_tbspace NAME,
    resolution VARCHAR(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            current_schema, source_table, current_schema, dest_table, dest_tbspace, resolution));
$$;

CREATE OR REPLACE FUNCTION create_history_table(
    source_table NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            source_table, dest_table, (
                SELECT spc.spcname
                FROM
                    pg_catalog.pg_class cls
                    LEFT JOIN pg_catalog.pg_tablespace spc
                        ON cls.reltablespace = spc.oid
                WHERE cls.oid = CAST(
                    quote_ident(current_schema) || '.' || quote_ident(source_table)
                    AS regclass)
            ), resolution));
$$;

CREATE OR REPLACE FUNCTION create_history_table(
    source_table NAME,
    resolution VARCHAR(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            source_table, source_table || '_history', resolution));
$$;

GRANT EXECUTE ON FUNCTION create_history_table(NAME, NAME, NAME, NAME, NAME, VARCHAR) TO utils_history_user;
GRANT EXECUTE ON FUNCTION create_history_table(NAME, NAME, NAME, VARCHAR)             TO utils_history_user;
GRANT EXECUTE ON FUNCTION create_history_table(NAME, NAME, VARCHAR)                   TO utils_history_user;
GRANT EXECUTE ON FUNCTION create_history_table(NAME, VARCHAR)                         TO utils_history_user;

GRANT ALL ON FUNCTION create_history_table(NAME, NAME, NAME, NAME, NAME, VARCHAR) TO utils_history_admin WITH GRANT OPTION;
GRANT ALL ON FUNCTION create_history_table(NAME, NAME, NAME, VARCHAR)             TO utils_history_admin WITH GRANT OPTION;
GRANT ALL ON FUNCTION create_history_table(NAME, NAME, VARCHAR)                   TO utils_history_admin WITH GRANT OPTION;
GRANT ALL ON FUNCTION create_history_table(NAME, VARCHAR)                         TO utils_history_admin WITH GRANT OPTION;

