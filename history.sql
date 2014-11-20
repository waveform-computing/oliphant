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

CREATE FUNCTION x_history_periodlen(resolution VARCHAR(12))
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

CREATE FUNCTION x_history_periodstep(resolution VARCHAR(12))
    RETURNS INTERVAL
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
        THEN INTERVAL '1 day'
        ELSE INTERVAL '1 microsecond'
    END);
$$;

CREATE FUNCTION x_history_periodstep(source_schema NAME, source_table NAME)
    RETURNS INTERVAL
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (CASE (
        SELECT format_type(a.atttypid, NULL)
        FROM
            pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c
                ON a.attrelid = c.oid
            JOIN pg_catalog.pg_namespace n
                ON c.relnamespace = n.oid
        WHERE
            n.nspname = source_schema
            AND c.relname = source_table
            AND a.attnum = 1
        )
        WHEN 'timestamp without time zone' THEN INTERVAL '1 microsecond'
        WHEN 'date' THEN INTERVAL '1 day'
    END);
$$;

CREATE FUNCTION x_history_effname(resolution VARCHAR(12))
    RETURNS NAME
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CAST('effective' AS name));
$$;

CREATE FUNCTION x_history_effname(source_schema NAME, source_table NAME)
    RETURNS NAME
    LANGUAGE SQL
    STABLE
AS $$
    SELECT a.attname
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c
            ON a.attrelid = c.oid
        JOIN pg_catalog.pg_namespace n
            ON c.relnamespace = n.oid
    WHERE
        n.nspname = source_schema
        AND c.relname = source_table
        AND a.attnum = 1;
$$;

CREATE FUNCTION x_history_expname(resolution VARCHAR(12))
    RETURNS NAME
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CAST('expiry' AS NAME));
$$;

CREATE FUNCTION x_history_expname(source_schema NAME, source_table NAME)
    RETURNS NAME
    LANGUAGE SQL
    STABLE
AS $$
    SELECT a.attname
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c
            ON a.attrelid = c.oid
        JOIN pg_catalog.pg_namespace n
            ON c.relnamespace = n.oid
    WHERE
        n.nspname = source_schema
        AND c.relname = source_table
        AND a.attnum = 2;
$$;

CREATE FUNCTION x_history_effdefault(resolution VARCHAR(12))
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

CREATE FUNCTION x_history_effdefault(source_schema NAME, source_table NAME)
    RETURNS TEXT
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        d.adsrc
    FROM
        pg_catalog.pg_namespace n
        JOIN pg_catalog.pg_class c
            ON c.relnamespace = n.oid
        JOIN pg_catalog.pg_attribute a
            ON a.attrelid = c.oid
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = c.oid
            AND d.adnum = a.attnum
    WHERE
        n.nspname = source_schema
        AND c.relname = source_table
        AND a.attnum = 1;
$$;

CREATE FUNCTION x_history_expdefault(resolution VARCHAR(12))
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

CREATE FUNCTION x_history_expdefault(source_schema name, source_table name)
    RETURNS text
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        d.adsrc
    FROM
        pg_catalog.pg_namespace n
        JOIN pg_catalog.pg_class c
            ON c.relnamespace = n.oid
        JOIN pg_catalog.pg_attribute a
            ON a.attrelid = c.oid
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = c.oid
            AND d.adnum = a.attnum
    WHERE
        n.nspname = source_schema
        AND c.relname = source_table
        AND a.attnum = 2;
$$;

CREATE FUNCTION x_history_periodstart(resolution VARCHAR(12), expression TEXT)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        'date_trunc(' || quote_literal(resolution) || ', ' || expression || ')'
    );
$$;

CREATE FUNCTION x_history_periodend(resolution VARCHAR(12), expression TEXT)
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

CREATE FUNCTION x_history_effnext(resolution VARCHAR(12), shift INTERVAL)
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

CREATE FUNCTION x_history_expprior(resolution VARCHAR(12), shift INTERVAL)
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

CREATE FUNCTION x_history_insert(
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
        SELECT a.attname
        FROM
            pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c
                ON a.attrelid = c.oid
            JOIN pg_catalog.pg_namespace n
                ON c.relnamespace = n.oid
        WHERE
            n.nspname = source_schema
            AND c.relname = source_table
        ORDER BY a.attnum
    LOOP
        insert_stmt := insert_stmt || ',' || quote_ident(r.attname);
        values_stmt := values_stmt || ',NEW.' || quote_ident(r.attname);
    END LOOP;
    insert_stmt := insert_stmt || ')';
    values_stmt := values_stmt || ')';
    RETURN insert_stmt || values_stmt;
END;
$$;

CREATE FUNCTION x_history_expire(
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
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            JOIN unnest((
                SELECT con.conkey
                FROM
                    pg_catalog.pg_constraint con
                    JOIN pg_catalog.pg_class rel
                        ON con.conrelid = rel.oid
                    JOIN pg_catalog.pg_namespace nsp
                        ON rel.relnamespace = nsp.oid
                WHERE
                    nsp.nspname = source_schema
                    AND rel.relname = source_table
                    AND con.contype = 'p'
                )) AS key(attnum)
                ON att.attnum = key.attnum
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
    LOOP
        update_stmt := update_stmt || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN update_stmt;
END;
$$;

CREATE FUNCTION x_history_update(
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
        SELECT att.attname, COALESCE(key.attnum, 0) AS keynum
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            LEFT JOIN unnest((
                SELECT con.conkey
                FROM
                    pg_catalog.pg_constraint con
                    JOIN pg_catalog.pg_class rel
                        ON con.conrelid = rel.oid
                    JOIN pg_catalog.pg_namespace nsp
                        ON rel.relnamespace = nsp.oid
                WHERE
                    nsp.nspname = source_schema
                    AND rel.relname = source_table
                    AND con.contype = 'p'
                )) AS key(attnum)
                ON att.attnum = key.attnum
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
            AND att.attnum > 0
    LOOP
        IF r.keynum = 0 THEN
            set_stmt := set_stmt || ', ' || quote_ident(r.attname) || ' = NEW.' || quote_ident(r.attname);
        ELSE
            where_stmt := where_stmt || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
        END IF;
    END LOOP;
    set_stmt = 'SET' || substring(set_stmt from 2);
    RETURN update_stmt || set_stmt || where_stmt;
END;
$$;

CREATE FUNCTION x_history_delete(
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
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            JOIN unnest((
                SELECT con.conkey
                FROM
                    pg_catalog.pg_constraint con
                    JOIN pg_catalog.pg_class rel
                        ON con.conrelid = rel.oid
                    JOIN pg_catalog.pg_namespace nsp
                        ON rel.relnamespace = nsp.oid
                WHERE
                    nsp.nspname = source_schema
                    AND rel.relname = source_table
                    AND con.contype = 'p'
                )) AS key(attnum)
                ON att.attnum = key.attnum
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
    LOOP
        where_stmt = where_stmt || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN delete_stmt || where_stmt;
END;
$$;

CREATE FUNCTION x_history_check(
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
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            JOIN unnest((
                SELECT con.conkey
                FROM
                    pg_catalog.pg_constraint con
                    JOIN pg_catalog.pg_class rel
                        ON con.conrelid = rel.oid
                    JOIN pg_catalog.pg_namespace nsp
                        ON rel.relnamespace = nsp.oid
                WHERE
                    nsp.nspname = source_schema
                    AND rel.relname = source_table
                    AND con.contype = 'p'
                )) AS key(attnum)
                ON att.attnum = key.attnum
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
    LOOP
        where_stmt := where_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN select_stmt || where_stmt;
END;
$$;

CREATE FUNCTION x_history_changes(
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
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = rel.oid
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
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

CREATE FUNCTION x_history_snapshots(
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
        SELECT a.attname
        FROM
            pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c
                ON a.attrelid = c.oid
            JOIN pg_catalog.pg_namespace n
                ON c.relnamespace = n.oid
        WHERE
            n.nspname = source_schema
            AND c.relname = source_table
            AND a.attnum > 2
        ORDER BY a.attnum
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

CREATE FUNCTION x_history_update_fields(
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
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = rel.oid
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
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

CREATE FUNCTION x_history_update_when(
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
            JOIN pg_catalog.pg_class rel
                ON att.attrelid = rel.oid
            JOIN pg_catalog.pg_namespace nsp
                ON rel.relnamespace = nsp.oid
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = rel.oid
        WHERE
            nsp.nspname = source_schema
            AND rel.relname = source_table
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

