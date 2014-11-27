-------------------------------------------------------------------------------
-- AUTHORIZATION UTILITIES
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
-- The following routines aid in manipulating authorizations en masse in the
-- database. The allow all authorizations associated with a given user, group
-- or role to be transferred to other users, groups, or roles, removed
-- entirely, or queried as a whole.
--
-- In each routine, grantees are identified by two parameters, AUTH_NAME which
-- holds the name of the grantee and AUTH_TYPE which holds the type of the
-- grantee where U=User, G=Group, and R=Role. Typically the AUTH_TYPE parameter
-- can be omitted in which case the type will be determined automatically if
-- possible.
-------------------------------------------------------------------------------


-- ROLES
-------------------------------------------------------------------------------
-- The following roles grant usage and administrative rights to the objects
-- created by this module.
-------------------------------------------------------------------------------

CREATE ROLE utils_auth_user;
CREATE ROLE utils_auth_admin;

--GRANT utils_auth_user TO utils_user;
GRANT utils_auth_user TO utils_auth_admin WITH ADMIN OPTION;
--GRANT utils_auth_admin TO utils_admin WITH ADMIN OPTION;

-- SQLSTATES
-------------------------------------------------------------------------------
-- The following variables define the set of SQLSTATEs raised by the procedures
-- and functions in this module.
-------------------------------------------------------------------------------

--CREATE VARIABLE AUTH_AMBIGUOUS_STATE CHAR(5) CONSTANT '90002';
--
--GRANT READ ON VARIABLE AUTH_AMBIGUOUS_STATE TO ROLE UTILS_AUTH_USER;
--GRANT ALL ON VARIABLE AUTH_AMBIGUOUS_STATE TO ROLE UTILS_AUTH_ADMIN WITH GRANT OPTION;
--
--COMMENT ON VARIABLE AUTH_AMBIGUOUS_STATE
--    IS 'The SQLSTATE raised when an authentication type is ambiguous (e.g. refers to both a user & group)';

-- auths_held(auth_name)
-------------------------------------------------------------------------------
-- This is a utility function used by the copy_auth procedure, and other
-- associated procedures, below. Given an authorization name, and a flag, this
-- table function returns the details of all the authorizations held by that
-- name (excluding column authorizations). The information returned is
-- sufficient for comparison of authorizations and generation of GRANT/REVOKE
-- statements.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION auths_held(
    auth_name name
)
    RETURNS TABLE (
        object_type varchar(20),
        object_id varchar(100),
        auth varchar(140),
        suffix varchar(20)
    )
    LANGUAGE SQL
    STABLE
AS $$
    WITH all_db_auths(auth) AS (
        VALUES
            ('CREATE'),
            ('CONNECT'),
            ('TEMPORARY')
    ),
    db_auths AS (
        SELECT
            CAST('DATABASE' AS varchar),
            CAST(current_database() AS varchar),
            auth,
            CASE WHEN has_database_privilege(auth_name, current_database(), auth || ' WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            all_db_auths
        WHERE
            has_database_privilege(auth_name, current_database(), auth)
    ),
    role_auths AS (
        SELECT
            CAST('' AS varchar),
            CAST('' AS varchar),
            quote_ident(rolname),
            CASE WHEN pg_has_role(auth_name, rolname, 'USAGE WITH ADMIN OPTION')
                THEN 'WITH ADMIN OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_roles
        WHERE
            pg_has_role(auth_name, rolname, 'USAGE')
    ),
    foreign_data_wrapper_auths AS (
        SELECT
            CAST('FOREIGN DATA WRAPPER' AS varchar),
            quote_ident(fdwname),
            CAST('USAGE' AS varchar),
            CASE WHEN has_foreign_data_wrapper_privilege(auth_name, quote_ident(fdwname), 'USAGE WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_foreign_data_wrapper
        WHERE
            has_foreign_data_wrapper_privilege(auth_name, quote_ident(fdwname), 'USAGE')
    ),
    foreign_server_auths AS (
        SELECT
            CAST('FOREIGN SERVER' AS varchar),
            quote_ident(srvname),
            CAST('USAGE' AS varchar),
            CASE WHEN has_server_privilege(auth_name, quote_ident(srvname), 'USAGE WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_foreign_server
        WHERE
            has_server_privilege(auth_name, quote_ident(srvname), 'USAGE')
    ),
    function_auths AS (
        SELECT
            CAST('FUNCTION' AS varchar),
            CAST(CAST(oid AS regprocedure) AS varchar),
            CAST('EXECUTE' AS varchar),
            CASE WHEN has_function_privilege(auth_name, CAST(oid AS regprocedure), 'EXECUTE WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_proc
        WHERE
            has_function_privilege(auth_name, CAST(oid AS regprocedure), 'EXECUTE')
    ),
    language_auths AS (
        SELECT
            CAST('LANGUAGE' AS varchar),
            quote_ident(lanname),
            CAST('USAGE' AS varchar),
            CASE WHEN has_language_privilege(auth_name, quote_ident(lanname), 'USAGE WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_language
        WHERE
            has_language_privilege(auth_name, quote_ident(lanname), 'USAGE')
            AND lanpltrusted
    ),
    all_schema_auths(auth) AS (
        VALUES
            ('CREATE'),
            ('USAGE')
    ),
    schema_auths AS (
        SELECT
            CAST('SCHEMA' AS varchar),
            quote_ident(nspname),
            auth,
            CASE WHEN has_schema_privilege(auth_name, quote_ident(nspname), auth || ' WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_namespace
            CROSS JOIN all_schema_auths
        WHERE
            has_schema_privilege(auth_name, quote_ident(nspname), auth)
    ),
    all_sequence_auths(auth) AS (
        VALUES
            ('SELECT'),
            ('USAGE'),
            ('UPDATE')
    ),
    sequence_auths AS (
        SELECT
            CAST('SEQUENCE' AS varchar),
            CAST(CAST(oid AS regclass) AS varchar),
            auth,
            -- XXX There seems to be an issue that although WITH GRANT OPTION
            -- is implemented by GRANT on sequences, it's not supported by the
            -- has_sequence_privilege() function. Might want to submit a patch
            -- for this...
            CAST('' AS varchar)
        FROM
            pg_catalog.pg_class,
            all_sequence_auths
        WHERE
            has_sequence_privilege(auth_name, CAST(oid AS regclass), auth)
            AND relkind = 'S'
    ),
    all_table_auths(auth) AS (
        VALUES
            ('SELECT'),
            ('INSERT'),
            ('UPDATE'),
            ('DELETE'),
            ('TRUNCATE'),
            ('REFERENCES'),
            ('TRIGGER')
    ),
    table_auths AS (
        SELECT
            CAST('TABLE' AS varchar),
            CAST(CAST(oid AS regclass) AS varchar),
            auth,
            CASE WHEN has_table_privilege(auth_name, CAST(oid AS regclass), auth || ' WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_class,
            all_table_auths
        WHERE
            has_table_privilege(auth_name, CAST(oid AS regclass), auth)
            AND relkind IN ('r', 'v', 'm')
    ),
    tablespace_auths AS (
        SELECT
            CAST('TABLESPACE' AS varchar),
            quote_ident(spcname),
            CAST('CREATE' AS varchar),
            CASE WHEN has_tablespace_privilege(auth_name, quote_ident(spcname), 'CREATE WITH GRANT OPTION')
                THEN 'WITH GRANT OPTION'
                ELSE ''
            END
        FROM
            pg_catalog.pg_tablespace
        WHERE
            has_tablespace_privilege(auth_name, quote_ident(spcname), 'CREATE')
    )
    SELECT * FROM db_auths                   UNION
    SELECT * FROM role_auths                 UNION
    SELECT * FROM foreign_data_wrapper_auths UNION
    SELECT * FROM foreign_server_auths       UNION
    SELECT * FROM function_auths             UNION
    SELECT * FROM language_auths             UNION
    SELECT * FROM schema_auths               UNION
    SELECT * FROM sequence_auths             UNION
    SELECT * FROM table_auths                UNION
    SELECT * FROM tablespace_auths;
$$;

GRANT EXECUTE ON FUNCTION
    auths_held(name)
    TO utils_auth_user;

GRANT ALL ON FUNCTION
    auths_held(name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION auths_held(name)
    IS 'Utility table function which returns all the authorizations held by a specific name';

-- auth_diff(source, dest)
-------------------------------------------------------------------------------
-- This utility function determines the difference in authorizations held by
-- two different entities. Essentially it takes the authorizations of the
-- source entity and "subtracts" the authorizations of the dest entity, the
-- result being the authorizations that need to be granted to dest to give it
-- the same level of access as source.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION auth_diff(
    source name,
    dest name
)
    RETURNS TABLE(
        object_type varchar(20),
        object_id varchar(100),
        auth varchar(140),
        suffix varchar(20)
    )
    LANGUAGE SQL
    STABLE
AS $$
    WITH source_auths AS (
        SELECT * FROM auths_held(source)
    ),
    dest_auths AS (
        SELECT * FROM auths_held(dest)
    ),
    missing_auths AS (
        SELECT object_type, object_id, auth FROM source_auths EXCEPT
        SELECT object_type, object_id, auth FROM dest_auths
    ),
    missing_diff AS (
        SELECT sa.*
        FROM
            missing_auths ma
            JOIN source_auths sa
                ON ma.object_type = sa.object_type
                AND ma.object_id = sa.object_id
                AND ma.auth = sa.auth
    ),
    upgrade_auths AS (
        SELECT object_type, object_id, auth FROM source_auths INTERSECT
        SELECT object_type, object_id, auth FROM dest_auths
    ),
    upgrade_diff AS (
        SELECT sa.*
        FROM
            upgrade_auths ua
            JOIN source_auths sa
                ON ua.object_type = sa.object_type
                AND ua.object_id = sa.object_id
                AND ua.auth = sa.auth
            JOIN dest_auths da
                ON ua.object_type = da.object_type
                AND ua.object_id = da.object_id
                AND ua.auth = da.auth
        WHERE sa.auth <> '' AND da.auth = ''
    )
    SELECT * FROM missing_diff UNION
    SELECT * FROM upgrade_diff;
$$;

GRANT EXECUTE ON FUNCTION
    auth_diff(name, name)
    TO utils_auth_user;

GRANT EXECUTE ON FUNCTION
    auth_diff(name, name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION auth_diff(name, name)
    IS 'Utility table function which returns the difference between the authorities held by two names';

-- copy_auth(source, dest)
-------------------------------------------------------------------------------
-- copy_auth is a procedure which copies all authorizations from the source
-- grantee (source) to the destination grantee (dest). Note that the
-- implementation does not preserve the grantor, although technically this
-- would be possible by utilizing the SET SESSION AUTHORIZATION facility, nor
-- does it remove extra permissions that the destination grantee already
-- possessed prior to the call. Furthermore, column authorizations are not
-- copied.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION x_copy_list(
    source name,
    dest name
)
    RETURNS TABLE (
        object_type varchar(20),
        object_id varchar(100),
        ddl text
    )
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        object_type,
        object_id,
        'GRANT ' || auth ||
            CASE object_type
                WHEN '' THEN ''
                ELSE ' ON ' || object_type || ' ' || object_id
            END
            || ' TO ' || quote_ident(dest) || ' ' || suffix AS ddl
    FROM
        auth_diff(source, dest);
$$;

CREATE OR REPLACE FUNCTION copy_auth(
    source name,
    dest name
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT ddl
        FROM x_copy_list(source, dest)
    LOOP
        EXECUTE r.ddl;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION
    copy_auth(name, name)
    TO utils_auth_user;

GRANT EXECUTE ON FUNCTION
    copy_auth(name, name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION copy_auth(name, name)
    IS 'Grants all authorities held by the source to the target, provided they are not already held (i.e. does not "re-grant" authorities already held)';

-- remove_auth(auth_name)
-------------------------------------------------------------------------------
-- remove_auth is a procedure which removes all authorizations from the entity
-- specified by auth_name.
--
-- Note: this routine will not handle revoking column level authorizations.
-- Any such authorziations must be handled manually.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION x_remove_list(
    auth_name name
)
    RETURNS TABLE (
        object_type varchar(20),
        object_id varchar(100),
        auth varchar(140),
        ddl text
    )
    LANGUAGE SQL
    STABLE
AS $$
    SELECT
        object_type,
        object_id,
        auth,
        'REVOKE ' || auth ||
            CASE object_type
                WHEN '' THEN ''
                ELSE ' ON ' || object_type || ' ' || object_id
            END
            || ' FROM ' || quote_ident(auth_name) || ' CASCADE' AS ddl
    FROM
        auths_held(auth_name)
    WHERE
        NOT (object_type = '' AND auth = auth_name);
$$;

CREATE OR REPLACE FUNCTION remove_auth(
    auth_name name
)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT ddl
        FROM x_remove_list(auth_name)
    LOOP
        EXECUTE r.ddl;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION
    remove_auth(name)
    TO utils_auth_user;

GRANT EXECUTE ON FUNCTION
    remove_auth(name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION remove_auth(name)
    IS 'Removes all authorities held by the specified name';

-- move_auth(source, dest)
-------------------------------------------------------------------------------
-- move_auth is a procedure which moves all authorizations from the source
-- grantee (source) to the destination grantee (dest). Like copy_auth, this
-- procedure does not preserve the grantor.  Essentially this procedure
-- combines copy_auth and remove_auth to copy authorizations from source to
-- dest and then remove them from source.
--
-- Note that column authorizations will not be copied, and cannot be removed by
-- remove_auth. These should be handled separately.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION move_auth(
    source name,
    dest name
)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    SELECT copy_auth(source, dest);
    SELECT remove_auth(source);
$$;

GRANT EXECUTE ON FUNCTION
    move_auth(name, name)
    TO utils_auth_user;

GRANT EXECUTE ON FUNCTION
    move_auth(name, name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION move_auth(name, name)
    IS 'Moves all authorities held by the source to the target, provided they are not already held';

-- saved_auth
-------------------------------------------------------------------------------
-- A simple table which replicates the structure of the auths_held return table
-- for use by the save_auth and restore_auth procedures below.
-------------------------------------------------------------------------------

CREATE TABLE saved_auth AS (
    SELECT * FROM auths_held(current_user)
)
WITH NO DATA;

CREATE UNIQUE INDEX saved_auth_pk
    ON saved_auth (
        object_type,
        object_id,
        auth
    );

ALTER TABLE saved_auth
    ADD PRIMARY KEY USING INDEX saved_auth_pk;

GRANT ALL ON TABLE
    saved_auth
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON TABLE saved_auth
    IS 'Utility table used for temporary storage of authorizations by save_auth, save_auths, restore_auth and restore_auths et al';

-- save_auth(aschema, atable)
-- save_auth(atable)
-------------------------------------------------------------------------------
-- save_auth is a utility procedure which copies the authorization settings for
-- the specified table or view to the saved_auth table above. These saved
-- settings can then be restored with the restore_auth procedure declared
-- below.
--
-- NOTE: Column specific authorizations are NOT saved and restored by these
-- procedures.
-------------------------------------------------------------------------------
