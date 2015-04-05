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

-- Complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION history" to load this file. \quit

-- x_history_periodlen(resolution)
-- x_history_periodstep(resolution)
-- x_history_periodstep(source_schema, source_table)
-- x_history_effname(resolution)
-- x_history_effname(source_schema, source_table)
-- x_history_expname(resolution)
-- x_history_expname(source_schema, source_table)
-- x_history_effdefault(resolution)
-- x_history_effdefault(source_schema, source_table)
-- x_history_expdefault(resolution)
-- x_history_expdefault(source_schema, source_table)
-- x_history_periodstart(resolution, expression)
-- x_history_periodend(resolution, expression)
-- x_history_effnext(resolution, offset)
-- x_history_expprior(resolution, offset)
-- x_history_insert(source_schema, source_table, dest_schema, dest_table, resolution, offset)
-- x_history_expire(source_schema, source_table, dest_schema, dest_table, resolution, offset)
-- x_history_delete(source_schema, source_table, dest_schema, dest_table, resolution)
-- x_history_update(source_schema, source_table, dest_schema, dest_table, resolution)
-- x_history_check(source_schema, source_table, dest_schema, dest_table, resolution)
-- x_history_changes(source_schema, source_table, resolution)
-- x_history_snapshots(source_schema, source_table, resolution)
-- x_history_update_fields(source_schema, source_table, key_fields)
-- x_history_update_when(source_schema, source_table, key_fields)
-------------------------------------------------------------------------------
-- These functions are effectively private utility subroutines for the
-- procedures defined below. They simply generate snippets of SQL given a set
-- of input parameters.
-------------------------------------------------------------------------------

CREATE FUNCTION x_history_periodlen(resolution varchar(12))
    RETURNS interval
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE resolution
        WHEN 'quarter' THEN interval '3 months'
        WHEN 'millennium' THEN interval '1000 years'
        ELSE ('1 ' || resolution)::interval
    END);
$$;

CREATE FUNCTION x_history_periodstep(resolution varchar(12))
    RETURNS interval
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE WHEN x_history_periodlen(resolution) >= interval '1 day'
        THEN interval '1 day'
        ELSE interval '1 microsecond'
    END);
$$;

CREATE FUNCTION x_history_periodstep(source_schema name, source_table name)
    RETURNS interval
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (CASE (
            SELECT
                format_type(atttypid, NULL)
            FROM
                pg_catalog.pg_attribute
            WHERE
                attrelid = table_oid(source_schema, source_table)
                AND attnum = 1
            )
        WHEN 'timestamp without time zone' THEN interval '1 microsecond'
        WHEN 'timestamp with time zone' THEN interval '1 microsecond'
        WHEN 'date' THEN interval '1 day'
    END);
$$;

CREATE FUNCTION x_history_effname(resolution varchar(12))
    RETURNS name
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES ('effective'::name);
$$;

CREATE FUNCTION x_history_effname(source_schema name, source_table name)
    RETURNS name
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        attname
    FROM
        pg_catalog.pg_attribute
    WHERE
        attrelid = table_oid(source_schema, source_table)
        AND attnum = 1;
$$;

CREATE FUNCTION x_history_expname(resolution varchar(12))
    RETURNS name
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES ('expiry'::name);
$$;

CREATE FUNCTION x_history_expname(source_schema name, source_table name)
    RETURNS name
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        attname
    FROM
        pg_catalog.pg_attribute
    WHERE
        attrelid = table_oid(source_schema, source_table)
        AND attnum = 2;
$$;

CREATE FUNCTION x_history_effdefault(resolution varchar(12))
    RETURNS text
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        CASE WHEN x_history_periodlen(resolution) >= interval '1 day'
            THEN 'current_date'
            ELSE 'current_timestamp'
        END);
$$;

CREATE FUNCTION x_history_effdefault(source_schema name, source_table name)
    RETURNS text
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        d.adsrc
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = a.attrelid
            AND d.adnum = a.attnum
    WHERE
        a.attrelid = table_oid(source_schema, source_table)
        AND a.attnum = 1;
$$;

CREATE FUNCTION x_history_expdefault(resolution varchar(12))
    RETURNS text
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        CASE WHEN x_history_periodlen(resolution) >= interval '1 day'
            THEN 'date ''9999-12-31'''
            ELSE 'timestamp ''9999-12-31 23:59:59.999999'''
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
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = a.attrelid
            AND d.adnum = a.attnum
    WHERE
        a.attrelid = table_oid(source_schema, source_table)
        AND a.attnum = 2;
$$;

CREATE FUNCTION x_history_periodstart(resolution varchar(12), expression text)
    RETURNS text
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        format('date_trunc(%L, %s)', resolution, expression)
    );
$$;

CREATE FUNCTION x_history_periodend(resolution varchar(12), expression text)
    RETURNS text
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        format('date_trunc(%L, %s) + interval %L - interval %L',
            resolution, expression,
            x_history_periodlen(resolution),
            x_history_periodstep(resolution)
        )
    );
$$;

CREATE FUNCTION x_history_effnext(resolution varchar(12), shift interval)
    RETURNS text
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        x_history_periodstart(
            resolution, x_history_effdefault(resolution)
            || CASE WHEN shift IS NOT NULL
                THEN format(' + interval %L', shift)
                ELSE ''
            END)
    );
$$;

CREATE FUNCTION x_history_expprior(resolution varchar(12), shift interval)
    RETURNS text
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        x_history_periodend(
            resolution, x_history_effdefault(resolution)
            || format(' - interval %L', x_history_periodlen(resolution))
            || CASE WHEN shift IS NOT NULL
                THEN format(' + interval %L', shift)
                ELSE ''
            END)
    );
$$;

CREATE FUNCTION x_history_insert(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    resolution varchar(12),
    shift interval
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    insert_stmt text DEFAULT '';
    values_stmt text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            attname
        FROM
            pg_catalog.pg_attribute
        WHERE
            attrelid = table_oid(source_schema, source_table)
            AND attnum > 0
            AND NOT attisdropped
        ORDER BY attnum
    LOOP
        insert_stmt := insert_stmt || format(', %I', r.attname);
        values_stmt := values_stmt || format(', new.%I', r.attname);
    END LOOP;

    RETURN format(
        $sql$
        INSERT INTO %I.%I (%I%s) VALUES (%s%s)
        $sql$,

        dest_schema, dest_table,
        x_history_effname(dest_schema, dest_table),
        insert_stmt,
        x_history_effnext(resolution, shift),
        values_stmt
    );
END;
$$;

CREATE FUNCTION x_history_expire(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    resolution varchar(12),
    shift interval
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    update_stmt text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        update_stmt := update_stmt || format(' AND %I = old.%I', r.attname, r.attname);
    END LOOP;

    RETURN format(
        $sql$
        UPDATE %I.%I SET %I = %s
        WHERE %I = %s
        %s
        $sql$,

        dest_schema, dest_table,
        x_history_expname(dest_schema, dest_table),
        x_history_expprior(resolution, shift),
        x_history_expname(dest_schema, dest_table),
        x_history_expdefault(resolution),
        update_stmt
    );
END;
$$;

CREATE FUNCTION x_history_update(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    resolution varchar(12)
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    set_stmt text DEFAULT '';
    where_stmt text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            att.attname,
            ARRAY [att.attnum] <@ con.conkey AS iskey
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND con.contype = 'p'
    LOOP
        IF r.iskey THEN
            where_stmt := where_stmt || format(' AND %I = old.%I', r.attname, r.attname);
        ELSE
            set_stmt := set_stmt || format(', %I = new.%I', r.attname, r.attname);
        END IF;
    END LOOP;

    RETURN format(
        $sql$
        UPDATE %I.%I SET %s
        WHERE %I = %s
        %s
        $sql$,

        dest_schema, dest_table,
        substring(set_stmt from 2),
        x_history_expname(dest_schema, dest_table),
        x_history_expdefault(resolution),
        where_stmt
    );
END;
$$;

CREATE FUNCTION x_history_delete(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    resolution varchar(12)
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    where_stmt text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        where_stmt := where_stmt || format(' AND %I = old.%I', r.attname, r.attname);
    END LOOP;

    RETURN format(
        $sql$
        DELETE FROM %I.%I
        WHERE %I = %s
        %s
        $sql$,

        dest_schema, dest_table,
        x_history_expname(dest_schema, dest_table),
        x_history_expdefault(resolution),
        where_stmt
    );
END;
$$;

CREATE FUNCTION x_history_check(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    resolution varchar(12)
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    where_stmt text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        where_stmt := where_stmt || format(' AND %I = old.%I', r.attname, r.attname);
    END LOOP;

    RETURN format(
        $sql$
        SELECT %s
        FROM %I.%I
        WHERE %I = %s
        %s
        $sql$,

        x_history_periodend(resolution, x_history_effname(dest_schema, dest_table)),
        dest_schema, dest_table,
        x_history_expname(dest_schema, dest_table),
        x_history_expdefault(resolution),
        where_stmt
    );
END;
$$;

CREATE FUNCTION x_history_changes(
    source_schema name,
    source_table name
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt text DEFAULT '';
    from_stmt text DEFAULT '';
    insert_test text DEFAULT '';
    update_test text DEFAULT '';
    delete_test text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            att.attname,
            ARRAY [att.attnum] <@ con.conkey AS iskey
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND con.contype = 'p'
            AND att.attnum > 2
            AND NOT att.attisdropped
    LOOP
        select_stmt := select_stmt
            || format(', old.%I AS %I', r.attname, 'old_' || r.attname)
            || format(', new.%I AS %I', r.attname, 'new_' || r.attname);
        IF r.iskey THEN
            from_stmt := from_stmt
                || format(' AND old.%I = new.%I', r.attname, r.attname);
            insert_test := insert_test
                || format('AND old.%I IS NULL AND new.%I IS NOT NULL ', r.attname, r.attname);
            update_test := update_test
                || format('AND old.%I IS NOT NULL AND new.%I IS NOT NULL ', r.attname, r.attname);
            delete_test := delete_test
                || format('AND old.%I IS NOT NULL AND new.%I IS NULL ', r.attname, r.attname);
        END IF;
    END LOOP;

    RETURN format(
        $sql$
        WITH %I AS (
            SELECT *
            FROM %I.%I
            WHERE %I < %s
        )
        SELECT
            coalesce(new.%I, old.%I + interval %L) AS changed,
            CAST(CASE
                WHEN %s THEN 'INSERT'
                WHEN %s THEN 'UPDATE'
                WHEN %s THEN 'DELETE'
                ELSE 'ERROR'
            END AS char(6)) AS change
            %s
        FROM
            %I AS old FULL JOIN %I.%I AS new
            ON new.%I - interval %L BETWEEN old.%I AND old.%I
            %s
        $sql$,

        'old_' || source_table,
        source_schema, source_table,
        x_history_expname(source_schema, source_table),
        x_history_expdefault(source_schema, source_table),
        x_history_effname(source_schema, source_table),
        x_history_expname(source_schema, source_table),
        x_history_periodstep(source_schema, source_table),
        substring(insert_test from 4),
        substring(update_test from 4),
        substring(delete_test from 4),
        select_stmt,
        'old_' || source_table,
        source_schema, source_table,
        x_history_effname(source_schema, source_table),
        x_history_periodstep(source_schema, source_table),
        x_history_effname(source_schema, source_table),
        x_history_expname(source_schema, source_table),
        from_stmt
    );
END;
$$;

CREATE FUNCTION x_history_snapshots(
    source_schema name,
    source_table name,
    resolution varchar(12)
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            attname
        FROM
            pg_catalog.pg_attribute
        WHERE
            attrelid = table_oid(source_schema, source_table)
            AND attnum > 2
            AND NOT attisdropped
        ORDER BY attnum
    LOOP
        select_stmt := select_stmt || format(', h.%I', r.attname);
    END LOOP;

    RETURN format(
        $sql$
        WITH RECURSIVE range(at) AS (
            SELECT min(%I)::timestamp
            FROM %I.%I
            UNION ALL
            SELECT at + interval %L
            FROM range
            WHERE at <= %s
        )
        SELECT
            %s AS snapshot
            %s
        FROM
            range AS r JOIN %I.%I AS h
            ON r.at BETWEEN h.%I AND h.%I
        $sql$,

        x_history_effname(source_schema, source_table),
        source_schema, source_table,
        x_history_periodlen(resolution),
        x_history_effdefault(resolution),
        x_history_periodend(resolution, 'r.at'),
        select_stmt,
        source_schema, source_table,
        x_history_effname(source_schema, source_table),
        x_history_expname(source_schema, source_table)
    );
END;
$$;

CREATE FUNCTION x_history_update_fields(
    source_schema name,
    source_table name,
    key_fields boolean
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    result text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT
            att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND (
                (key_fields AND ARRAY [att.attnum] <@ con.conkey) OR
                NOT (key_fields OR ARRAY [att.attnum] <@ con.conkey)
            )
        ORDER BY att.attnum
    LOOP
        result := result || format(',%I', r.attname);
    END LOOP;

    RETURN substring(result from 2);
END;
$$;

CREATE FUNCTION x_history_update_when(
    source_schema name,
    source_table name,
    key_fields boolean
)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    result text DEFAULT '';
    r record;
BEGIN
    FOR r IN
        SELECT att.attname, att.attnotnull
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND (
                (key_fields AND ARRAY [att.attnum] <@ con.conkey) OR
                NOT (key_fields OR ARRAY [att.attnum] <@ con.conkey)
            )
        ORDER BY att.attnum
    LOOP
        result := result || format(' OR old.%I <> new.%I', r.attname, r.attname);
        IF NOT r.attnotnull THEN
            result := result
                || format(' OR (old.%I IS NULL AND new.%I IS NOT NULL)', r.attname, r.attname)
                || format(' OR (new.%I IS NULL AND old.%I IS NOT NULL)', r.attname, r.attname);
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

CREATE FUNCTION create_history_table(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    dest_tbspace name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    key_name name DEFAULT '';
    key_cols text DEFAULT '';
    r record;
BEGIN
    PERFORM assert_table_exists(source_schema, source_table);
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
            format(
                $sql$
                DROP TABLE %I.%I
                $sql$,

                dest_schema, dest_table
            ) AS drop_cmd
        FROM
            pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n
                ON c.relnamespace = n.oid
        WHERE
            n.nspname = dest_schema
            AND c.relname = dest_table
    LOOP
        EXECUTE r.drop_cmd;
    END LOOP;

    -- Calculate comma-separated lists of key columns in the order they are
    -- declared in the primary key (for generation of constraints later)
    FOR r IN
        WITH subscripts(i) AS (
            SELECT
                generate_subscripts(conkey, 1)
            FROM
                pg_catalog.pg_constraint
            WHERE
                conrelid = table_oid(source_schema, source_table)
                AND contype = 'p'
        )
        SELECT
            att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
            JOIN subscripts sub
                ON att.attnum = con.conkey[sub.i]
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND NOT att.attisdropped
        ORDER BY sub.i
    LOOP
        key_cols := key_cols
            || quote_ident(r.attname) || ',';
    END LOOP;

    -- Create the history table based on the source table
    EXECUTE format(
        $sql$
        CREATE TABLE %I.%I AS (
            SELECT
                %s AS %I,
                %s AS %I,
                t.*
            FROM
                %I.%I AS t
        ) WITH NO DATA
        $sql$,

        dest_schema, dest_table,
        x_history_effdefault(resolution),
        x_history_effname(resolution),
        x_history_expdefault(resolution),
        x_history_expname(resolution),
        source_schema, source_table
    ) || CASE WHEN dest_tbspace IS NOT NULL
        THEN format(' TABLESPACE %I', dest_tbspace)
        ELSE ''
    END;

    -- Copy NOT NULL constraints from the source table to the history table
    FOR r IN
        SELECT
            attname
        FROM
            pg_catalog.pg_attribute
        WHERE
            attrelid = table_oid(source_schema, source_table)
            AND attnotnull
            AND attnum > 0
            AND NOT attisdropped
    LOOP
        EXECUTE format(
            $sql$
            ALTER TABLE %I.%I ALTER COLUMN %I SET NOT NULL
            $sql$,

            dest_schema, dest_table, r.attname
        );
    END LOOP;

    -- Copy CHECK and EXCLUDE constraints from the source table to the history
    -- table. Note that we do not copy FOREIGN KEY constraints as there's no
    -- good method of matching a parent record in a historized table.
    FOR r IN
        SELECT
            pg_get_constraintdef(oid) AS con_def
        FROM
            pg_catalog.pg_constraint
        WHERE
            conrelid = table_oid(source_schema, source_table)
            AND contype IN ('c', 'x')
    LOOP
        EXECUTE format(
            $sql$
            ALTER TABLE %I.%I ADD %s
            $sql$,

            dest_schema, dest_table, r.con_def
        );
    END LOOP;

    -- Create two unique constraints, both based on the source table's primary
    -- key, plus the EFFECTIVE and EXPIRY fields respectively. Use INCLUDE for
    -- additional small fields in the EFFECTIVE index. The columns included are
    -- the same as those included in the primary key of the source table.
    -- TODO tablespaces...
    key_name := quote_ident(dest_table || '_pkey');
    EXECUTE format(
        $sql$
        CREATE UNIQUE INDEX %I ON %I.%I (%s %I)
        $sql$,

        dest_table || '_pkey',
        dest_schema, dest_table,
        key_cols, x_history_effname(resolution)
    );
    EXECUTE format(
        $sql$
        CREATE UNIQUE INDEX %I ON %I.%I (%s %I)
        $sql$,

        dest_table || '_ix1',
        dest_schema, dest_table,
        key_cols, x_history_expname(resolution)
    );

    -- Create additional indexes that are useful for performance purposes
    EXECUTE format(
        $sql$
        CREATE INDEX %I ON %I.%I (%I, %I)
        $sql$,

        dest_table || '_ix2',
        dest_schema, dest_table,
        x_history_effname(resolution),
        x_history_expname(resolution)
    );

    -- Create a primary key with the same fields as the EFFECTIVE index defined
    -- above.
    EXECUTE format(
        $sql$
        ALTER TABLE %I.%I
            ADD PRIMARY KEY USING INDEX %I,
            ADD CHECK (%I <= %I),
            ALTER COLUMN %I SET DEFAULT %s,
            ALTER COLUMN %I SET DEFAULT %s
        $sql$,

        dest_schema, dest_table,
        dest_table || '_pkey',
        x_history_effname(resolution), x_history_expname(resolution),
        x_history_effname(resolution), x_history_effdefault(resolution),
        x_history_expname(resolution), x_history_expdefault(resolution)
    );

    -- Store the source table's authorizations, then redirect them to the
    -- destination table filtering out those authorizations which should be
    -- excluded
    PERFORM save_auth(source_schema, source_table);
    UPDATE saved_auths SET
        table_schema = dest_schema,
        table_name = dest_table
    WHERE
        table_schema = source_schema
        AND table_name = source_table;
    --DELETE FROM saved_auths WHERE
    --    privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
    PERFORM restore_auth(dest_schema, dest_table);

    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    EXECUTE format(
        $sql$
        COMMENT ON TABLE %I.%I IS %L
        $sql$,

        dest_schema, dest_table,
        format('History table which tracks the content of @%I.%I',
            source_schema, source_table)
    );
    EXECUTE format(
        $sql$
        COMMENT ON COLUMN %I.%I.%I IS %L
        $sql$,

        dest_schema, dest_table, x_history_effname(resolution),
        'The date/timestamp from which this row was present in the source table'
    );
    EXECUTE format(
        $sql$
        COMMENT ON COLUMN %I.%I.%I IS %L
        $sql$,

        dest_schema, dest_table, x_history_expname(resolution),
        'The date/timestamp until which this row was present in the source '
        'table (rows with 9999-12-31 currently exist in the source table)'
    );
    FOR r IN
        SELECT
            attname,
            COALESCE(
                col_description(table_oid(source_schema, source_table), attnum),
                '') AS attdesc
        FROM
            pg_catalog.pg_attribute
        WHERE
            attrelid = table_oid(source_schema, source_table)
            AND attnum > 0
            AND NOT attisdropped
    LOOP
        EXECUTE format(
            $sql$
            COMMENT ON COLUMN %I.%I.%I IS %L
            $sql$,

            dest_schema, dest_table, r.attname,
            r.attdesc
        );
    END LOOP;
END;
$$;

CREATE FUNCTION create_history_table(
    source_table name,
    dest_table name,
    dest_tbspace name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            current_schema, source_table, current_schema, dest_table, dest_tbspace, resolution));
$$;

CREATE FUNCTION create_history_table(
    source_table name,
    dest_table name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            source_table, dest_table, (
                SELECT
                    spc.spcname
                FROM
                    pg_catalog.pg_class cls
                    LEFT JOIN pg_catalog.pg_tablespace spc
                        ON cls.reltablespace = spc.oid
                WHERE cls.oid = table_oid(current_schema, source_table)
            ), resolution));
$$;

CREATE FUNCTION create_history_table(
    source_table name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            source_table, source_table || '_history', resolution));
$$;

COMMENT ON FUNCTION CREATE_HISTORY_TABLE(name, name, name, name, name, varchar)
    IS 'Creates a temporal history table based on the structure of the specified table';
COMMENT ON FUNCTION CREATE_HISTORY_TABLE(name, name, name, varchar)
    IS 'Creates a temporal history table based on the structure of the specified table';
COMMENT ON FUNCTION CREATE_HISTORY_TABLE(name, name, varchar)
    IS 'Creates a temporal history table based on the structure of the specified table';
COMMENT ON FUNCTION CREATE_HISTORY_TABLE(name, varchar)
    IS 'Creates a temporal history table based on the structure of the specified table';

-- create_history_changes(source_schema, source_table, dest_schema, dest_view)
-- create_history_changes(source_table, dest_view)
-- create_history_changes(source_table)
-------------------------------------------------------------------------------
-- The create_history_changes procedure creates a view on top of a history
-- table which is assumed to have a structure generated by
-- create_history_table.  The view represents the history data as a series of
-- "change" rows. The "effective" and "expiry" columns from the source history
-- table are merged into a "changed" column while all other columns are
-- represented twice as an "old_" and "new_" variant.
--
-- If dest_view is not specified it defaults to the value of source_table with
-- "_history" replaced with "_changes". If dest_schema and source_schema are
-- not specified they default to the current schema.
--
-- All SELECT and CONTROL authorities present on the source table will be
-- copied to the destination table.
--
-- The type of change can be determined by querying the NULL state of the old
-- and new key columns. For example:
--
-- INSERT
-- If the old key or keys are NULL and the new are non-NULL, the change was an
-- insertion.
--
-- UPDATE
-- If both the old and new key or keys are non-NULL, the change was an update.
--
-- DELETE
-- If the old key or keys are non-NULL and the new are NULL, the change was a
-- deletion.
-------------------------------------------------------------------------------

CREATE FUNCTION create_history_changes(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_view name
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r record;
BEGIN
    PERFORM assert_table_exists(source_schema, source_table);
    EXECUTE format(
        $sql$
        CREATE VIEW %I.%I AS %s
        $sql$,

        dest_schema, dest_view, x_history_changes(source_schema, source_table)
    );

    -- Store the source table's authorizations, then redirect them to the
    -- destination table filtering out those authorizations which should be
    -- excluded
    PERFORM save_auth(source_schema, source_table);
    UPDATE saved_auths SET
        table_schema = dest_schema,
        table_name = dest_view
    WHERE
        table_schema = source_schema
        AND table_name = source_table;
    DELETE FROM saved_auths WHERE
        privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES');
    PERFORM restore_auth(dest_schema, dest_view);

    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    EXECUTE format(
        $sql$
        COMMENT ON COLUMN %I.%I.changed IS %L
        $sql$,

        dest_schema, dest_view, 'The date/timestamp on which this row changed'
    );
    EXECUTE format(
        $sql$
        COMMENT ON COLUMN %I.%I.change IS %L
        $sql$,

        dest_schema, dest_view, 'The type of change that occurred (INSERT/UPDATE/DELETE)'
    );
    EXECUTE format(
        $sql$
        COMMENT ON VIEW %I.%I IS %L
        $sql$,

        dest_schema, dest_view,
        format('View showing the content of @%I.%I as a series of changes',
            source_schema, source_table)
    );
    FOR r IN
        SELECT
            attname,
            COALESCE(
                col_description(table_oid(source_schema, source_table), attnum),
                '') AS attdesc
        FROM
            pg_catalog.pg_attribute
        WHERE
            attrelid = table_oid(source_schema, source_table)
            AND attnum > 2
            AND NOT attisdropped
    LOOP
        EXECUTE format(
            $sql$
            COMMENT ON COLUMN %I.%I.%I IS %L
            $sql$,

            dest_schema, dest_view, 'old_' || r.attname,
            format('Value of @%I.%I.%I prior to change',
                source_schema, source_table, r.attname)
        );
        EXECUTE format(
            $sql$
            COMMENT ON COLUMN %I.%I.%I IS %L
            $sql$,

            dest_schema, dest_view, 'new_' || r.attname,
            format('Value of @%I.%I.%I after change',
                source_schema, source_table, r.attname)
        );
    END LOOP;
END;
$$;

CREATE FUNCTION create_history_changes(
    source_table name,
    dest_view name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_changes(
            current_schema, source_table, current_schema, dest_view
        ));
$$;

CREATE FUNCTION create_history_changes(
    source_table name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_changes(
            source_table, replace(source_table, '_history', '_changes')
        ));
$$;

COMMENT ON FUNCTION create_history_changes(name, name, name, name)
    IS 'Creates an "OLD vs NEW" changes view on top of the specified history table';
COMMENT ON FUNCTION create_history_changes(name, name)
    IS 'Creates an "OLD vs NEW" changes view on top of the specified history table';
COMMENT ON FUNCTION create_history_changes(name)
    IS 'Creates an "OLD vs NEW" changes view on top of the specified history table';

-- create_history_snapshots(source_schema, source_table, dest_schema, dest_view, resolution)
-- create_history_snapshots(source_table, dest_view, resolution)
-- create_history_snapshots(source_table, resolution)
-------------------------------------------------------------------------------
-- The create_history_snapshots procedure creates a view on top of a history
-- table which is assumed to have a structure generated by
-- create_history_table.  The view represents the history data as a series of
-- "snapshots" of the main table at various points through time. The
-- "effective" and "expiry" columns from the source history table are replaced
-- with a "snapshot" column which indicates the timestamp or date of the
-- snapshot of the main table. All other columns are represented in their
-- original form.
--
-- If dest_view is not specified it defaults to the value of source_table with
-- "_history" replaced with a custom suffix which depends on the value of
-- resolution. For example, if resolution is 'month' then the suffix is
-- "monthly", if resolution is 'week' then the suffix is "weekly" and so on. If
-- dest_schema and source_schema are not specified they default to the current
-- schema.
--
-- The resolution parameter determines the amount of time between snapshots.
-- Snapshots will be generated for the end of each period given by a particular
-- resolution. For example, if resolution is 'week' then a snapshot will be
-- generated for the end of each week of the earliest record in the history
-- table up to the current date. See the create_history_trigger documentation
-- for a list of the possible values.
--
-- All SELECT and CONTROL authorities present on the source table will be
-- copied to the destination table.
-------------------------------------------------------------------------------

CREATE FUNCTION create_history_snapshots(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_view name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r record;
BEGIN
    PERFORM assert_table_exists(source_schema, source_table);
    EXECUTE format(
        $sql$
        CREATE VIEW %I.%I AS %s
        $sql$,

        dest_schema, dest_view,
        x_history_snapshots(source_schema, source_table, resolution)
    );

    -- Store the source table's authorizations, then redirect them to the
    -- destination table filtering out those authorizations which should be
    -- excluded
    PERFORM save_auth(source_schema, source_table);
    UPDATE saved_auths SET
        table_schema = dest_schema,
        table_name = dest_view
    WHERE
        table_schema = source_schema
        AND table_name = source_table;
    DELETE FROM saved_auths WHERE
        privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES');
    PERFORM restore_auth(dest_schema, dest_view);

    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    EXECUTE format(
        $sql$
        COMMENT ON COLUMN %I.%I.snapshot IS %L
        $sql$,

        dest_schema, dest_view, 'The date/timestamp of the row''s snapshot'
    );
    EXECUTE format(
        $sql$
        COMMENT ON VIEW %I.%I IS %L
        $sql$,

        dest_schema, dest_view, format(
            'View showing the content of @%I.%I as a series of snapshots',
            source_schema, source_table)
    );
    FOR r IN
        SELECT
            attname,
            COALESCE(
                col_description(table_oid(source_schema, source_table), attnum),
                '') AS attdesc
        FROM
            pg_catalog.pg_attribute
        WHERE
            attrelid = table_oid(source_schema, source_table)
            AND attnum > 2
            AND NOT attisdropped
    LOOP
        EXECUTE format(
            $sql$
            COMMENT ON COLUMN %I.%I.%I IS %L
            $sql$,

            dest_schema, dest_view, r.attname, format(
                'Value of @%I.%I.%I prior to change',
                source_schema, source_table, r.attname)
        );
    END LOOP;
END;
$$;

CREATE FUNCTION create_history_snapshots(
    source_table name,
    dest_view name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_snapshots(
            current_schema, source_table, current_schema, dest_view, resolution
    ));
$$;

CREATE FUNCTION create_history_snapshots(
    source_table name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_snapshots(
            source_table, replace(source_table, '_history', '_by_' || resolution), resolution
        ));
$$;

COMMENT ON FUNCTION create_history_snapshots(name, name, name, name, varchar)
    IS 'Creates an exploded view of the specified history table with one row per entity per resolution time-slice (e.g. daily, monthly, yearly, etc.)';
COMMENT ON FUNCTION create_history_snapshots(name, name, varchar)
    IS 'Creates an exploded view of the specified history table with one row per entity per resolution time-slice (e.g. daily, monthly, yearly, etc.)';
COMMENT ON FUNCTION create_history_snapshots(name, varchar)
    IS 'Creates an exploded view of the specified history table with one row per entity per resolution time-slice (e.g. daily, monthly, yearly, etc.)';

-- create_history_triggers(source_schema, source_table, dest_schema, dest_table, resolution, offset)
-- create_history_triggers(source_table, dest_table, resolution, offset)
-- create_history_triggers(source_table, resolution, offset)
-- create_history_triggers(source_table, resolution)
-------------------------------------------------------------------------------
-- The create_history_triggers procedure creates several trigger linking the
-- specified source table to the destination table which is assumed to have a
-- structure compatible with the result of running create_history_table above,
-- i.e. two extra columns called effective_date and expiry_date.
--
-- If dest_table is not specified it defaults to the value of source_table with
-- "_history" as a suffix. If dest_schema and source_schema are not specified
-- they default to the current schema.
--
-- The resolution parameter specifies the smallest unit of time that a history
-- entry can cover. This is effectively used to quantize the history. The value
-- given for the resolution parameter should match the value given as the
-- resolution parameter to the create_history_table procedure. The values
-- which can be specified are the same as the field parameter of the date_trunc
-- function.
--
-- The shift parameter specifies an SQL interval that will be used to offset
-- the effective dates of new history records. For example, if the source table
-- is only updated a week in arrears, then offset could be set to "- interval
-- '7 DAYS'" to cause the effective dates to be accurate.
-------------------------------------------------------------------------------

CREATE FUNCTION create_history_triggers(
    source_schema name,
    source_table name,
    dest_schema name,
    dest_table name,
    resolution varchar(12),
    shift interval
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r record;
    all_keys boolean;
BEGIN
    PERFORM assert_table_exists(source_schema, source_table);
    PERFORM assert_table_exists(dest_schema, dest_table);

    -- Determine whether the source table is "all key, no attributes"
    all_keys := (
        SELECT
            array_length(con.conkey, 1) = count(att.attnum)
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON att.attrelid = con.conrelid
        WHERE
            att.attrelid = table_oid(source_schema, source_table)
            AND att.attnum > 0
            AND NOT att.attisdropped
            AND con.contype = 'p'
        GROUP BY con.conkey
    );

    -- Drop any existing triggers with the same name as the destination
    -- triggers in case there are any left over
    FOR r IN
        SELECT format(
            $sql$
            DROP TRIGGER %I ON %s
            $sql$,

            tgname, tgrelid::regclass
        ) AS drop_trig
        FROM
            pg_catalog.pg_trigger
        WHERE
            tgrelid = table_oid(source_schema, source_table)
            AND tgname IN (
                source_table || '_keychg',
                source_table || '_insert',
                source_table || '_update',
                source_table || '_delete'
            )
    LOOP
        EXECUTE r.drop_trig;
    END LOOP;

    -- Drop any existing functions with the same name as the destination
    -- trigger functions
    FOR r IN
        SELECT format(
            $sql$
            DROP FUNCTION %s CASCADE
            $sql$,

            p.oid::regprocedure
        ) AS drop_func
        FROM
            pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n
                ON p.pronamespace = n.oid
        WHERE
            n.nspname = source_schema
            AND p.pronargs = 0
            AND p.prorettype = 'trigger'::regtype
            AND p.proname IN (
                source_table || '_keychg',
                source_table || '_insert',
                source_table || '_update',
                source_table || '_delete'
            )
    LOOP
        EXECUTE r.drop_func;
    END LOOP;

    -- Create the KEYCHG trigger
    EXECUTE format(
        $sql$
        CREATE FUNCTION %I.%I()
            RETURNS trigger
            LANGUAGE plpgsql
            IMMUTABLE
        AS $func$
        BEGIN
            RAISE EXCEPTION USING
                ERRCODE = %L,
                MESSAGE = %L,
                TABLE = %L;
            RETURN NULL;
        END;
        $func$
        $sql$,

        source_schema, source_table || '_keychg',
        'UTH01', format('Cannot update unique key of a row in %I.%I',
            source_schema, source_table),
        table_oid(source_schema, source_table)
    );
    EXECUTE format(
        $sql$
        CREATE TRIGGER %I
            BEFORE UPDATE OF %s
            ON %I.%I
            FOR EACH ROW
            WHEN (%s)
            EXECUTE PROCEDURE %I.%I()
        $sql$,

        source_table || '_keychg',
        x_history_update_fields(source_schema, source_table, true),
        source_schema, source_table,
        x_history_update_when(source_schema, source_table, true),
        source_schema, source_table || '_keychg'
    );

    -- Create the INSERT trigger
    EXECUTE format(
        $sql$
        CREATE FUNCTION %I.%I()
            RETURNS trigger
            LANGUAGE plpgsql
            VOLATILE
        AS $func$
        BEGIN
            %s;
            RETURN NEW;
        END;
        $func$
        $sql$,

        source_schema, source_table || '_insert',
        x_history_insert(
            source_schema, source_table,
            dest_schema, dest_table,
            resolution, shift)
    );
    EXECUTE format(
        $sql$
        CREATE TRIGGER %I
            AFTER INSERT ON %I.%I
            FOR EACH ROW
            EXECUTE PROCEDURE %I.%I()
        $sql$,

        source_table || '_insert',
        source_schema, source_table,
        source_schema, source_table || '_insert'
    );

    -- Create the UPDATE trigger
    IF NOT all_keys THEN
        EXECUTE format(
            $sql$
            CREATE FUNCTION %I.%I()
                RETURNS trigger
                LANGUAGE plpgsql
                VOLATILE
            AS $func$
            DECLARE
                chk_date timestamp;
            BEGIN
                chk_date := (
                    %s
                );
                IF %s > chk_date THEN
                    -- Expire current history row
                    %s;
                    IF NOT found THEN
                        RAISE EXCEPTION USING
                            ERRCODE = %L,
                            MESSAGE = %L,
                            TABLE = %L;
                    END IF;
                    -- Insert new history row
                    %s;
                ELSE
                    -- Update existing history row
                    %s;
                    IF NOT found THEN
                        RAISE EXCEPTION USING
                            ERRCODE = %L,
                            MESSAGE = %L,
                            TABLE = %L;
                    END IF;
                END IF;
                RETURN NEW;
            END;
            $func$
            $sql$,

            source_schema, source_table || '_update',
            x_history_check(
                source_schema, source_table, dest_schema, dest_table, resolution),
            x_history_effnext(resolution, shift),
            x_history_expire(
                source_schema, source_table, dest_schema, dest_table, resolution, shift),
            'UTH02', 'Failed to expire current history row',
            table_oid(dest_schema, dest_table),
            x_history_insert(
                source_schema, source_table, dest_schema, dest_table, resolution, shift),
            x_history_update(
                source_schema, source_table, dest_schema, dest_table, resolution),
            'UTH03', 'Failed to update current history row',
            table_oid(dest_schema, dest_table)
        );
        EXECUTE format(
            $sql$
            CREATE TRIGGER %I
                AFTER UPDATE OF %s
                ON %I.%I
                FOR EACH ROW
                WHEN (%s)
                EXECUTE PROCEDURE %I.%I()
            $sql$,

            source_table || '_update',
            x_history_update_fields(source_schema, source_table, false),
            source_schema, source_table,
            x_history_update_when(source_schema, source_table, false),
            source_schema, source_table || '_update'
        );
    END IF;

    -- Create the DELETE trigger
    EXECUTE format(
        $sql$
        CREATE FUNCTION %I.%I()
            RETURNS trigger
            LANGUAGE plpgsql
            VOLATILE
        AS $func$
        DECLARE
            chk_date timestamp;
        BEGIN
            chk_date := (
                %s
            );
            IF %s > chk_date THEN
                %s;
                IF NOT found THEN
                    RAISE EXCEPTION USING
                        ERRCODE = %L,
                        MESSAGE = %L,
                        TABLE = %L;
                END IF;
            ELSE
                %s;
                IF NOT found THEN
                    RAISE EXCEPTION USING
                        ERRCODE = %L,
                        MESSAGE = %L,
                        TABLE = %L;
                END IF;
            END IF;
            RETURN OLD;
        END;
        $func$
        $sql$,

        source_schema, source_table || '_delete',
        x_history_check(
            source_schema, source_table, dest_schema, dest_table, resolution),
        x_history_effnext(resolution, shift),
        x_history_expire(
            source_schema, source_table, dest_schema, dest_table, resolution, shift),
        'UTH02', 'Failed to expire current history row',
        table_oid(dest_schema, dest_table),
        x_history_delete(
            source_schema, source_table, dest_schema, dest_table, resolution),
        'UTH04', 'Failed to delete current history row',
        table_oid(dest_schema, dest_table)
    );
    EXECUTE format(
        $sql$
        CREATE TRIGGER %I
            AFTER DELETE ON %I.%I
            FOR EACH ROW
            EXECUTE PROCEDURE %I.%I()
        $sql$,

        source_table || '_delete',
        source_schema, source_table,
        source_schema, source_table || '_delete'
    );
END;
$$;

CREATE FUNCTION create_history_triggers(
    source_table name,
    dest_table name,
    resolution varchar(12),
    shift interval
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_triggers(
            current_schema, source_table, current_schema, dest_table, resolution, shift
        ));
$$;

CREATE FUNCTION create_history_triggers(
    source_table name,
    resolution varchar(12),
    shift interval
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_triggers(
            source_table, source_table || '_history', resolution, shift
        ));
$$;

CREATE FUNCTION create_history_triggers(
    source_table name,
    resolution varchar(12)
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_triggers(
            source_table, source_table || '_history', resolution, interval '0 microseconds'
        ));
$$;

COMMENT ON FUNCTION create_history_triggers(name, name, name, name, varchar, interval)
    IS 'Creates the triggers to link the specified table to its corresponding history table';
COMMENT ON FUNCTION create_history_triggers(name, name, varchar, interval)
    IS 'Creates the triggers to link the specified table to its corresponding history table';
COMMENT ON FUNCTION create_history_triggers(name, varchar, interval)
    IS 'Creates the triggers to link the specified table to its corresponding history table';
COMMENT ON FUNCTION create_history_triggers(name, varchar)
    IS 'Creates the triggers to link the specified table to its corresponding history table';

-- vim: set et sw=4 sts=4:
