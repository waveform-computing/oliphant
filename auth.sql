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
-- database. The allow all authorizations associated with a given role to be
-- transferred to other roles, removed entirely, or queried as a whole.
-------------------------------------------------------------------------------

-- ROLES
-------------------------------------------------------------------------------
-- The following roles grant usage and administrative rights to the objects
-- created by this module.
-------------------------------------------------------------------------------

DROP ROLE IF EXISTS utils_auth_user;
DROP ROLE IF EXISTS utils_auth_admin;
CREATE ROLE utils_auth_user;
CREATE ROLE utils_auth_admin;

GRANT utils_auth_user TO utils_user;
GRANT utils_auth_user TO utils_auth_admin WITH ADMIN OPTION;
GRANT utils_auth_admin TO utils_admin WITH ADMIN OPTION;

-- auths_held(auth_name)
-------------------------------------------------------------------------------
-- This is a utility function used by the copy_auth procedure, and other
-- associated procedures, below. Given an authorization name, and a flag, this
-- table function returns the details of all the authorizations held by that
-- name (excluding column authorizations). The information returned is
-- sufficient for comparison of authorizations and generation of GRANT/REVOKE
-- statements.
-------------------------------------------------------------------------------

CREATE FUNCTION auths_held(
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
    WITH
    role_auths AS (
        SELECT
            ''::varchar,
            ''::varchar,
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
    table_auths AS (
        SELECT
            'TABLE'::varchar,
            quote_ident(table_schema) || '.' || quote_ident(table_name),
            privilege_type,
            CASE WHEN is_grantable::boolean THEN 'WITH GRANT OPTION' ELSE '' END
        FROM
            information_schema.table_privileges
        WHERE
            grantee = auth_name
    ),
    routine_auths AS (
        SELECT
            'FUNCTION'::varchar,
            quote_ident(specific_schema) || '.' || quote_ident(specific_name),
            'EXECUTE'::varchar,
            CASE WHEN is_grantable::boolean THEN 'WITH GRANT OPTION' ELSE '' END
        FROM
            information_schema.routine_privileges
        WHERE
            grantee = auth_name
    )
    SELECT * FROM role_auths                 UNION
    -- XXX specific name isn't usable for anything at this time
    --SELECT * FROM routine_auths              UNION
    SELECT * FROM table_auths;
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

CREATE FUNCTION auth_diff(
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
        WHERE sa.suffix <> '' AND da.suffix = ''
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

CREATE FUNCTION x_copy_list(
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

CREATE FUNCTION copy_auth(
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

CREATE FUNCTION x_remove_list(
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

CREATE FUNCTION remove_auth(
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

CREATE FUNCTION move_auth(
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

CREATE TABLE saved_auths AS (
    SELECT table_schema, table_name, grantee, privilege_type, is_grantable::boolean
    FROM information_schema.table_privileges
) WITH NO DATA;

CREATE UNIQUE INDEX saved_auths_pk
    ON saved_auths (table_schema, table_name, grantee, privilege_type);

ALTER TABLE saved_auths
    ADD PRIMARY KEY USING INDEX saved_auths_pk,
    ALTER COLUMN is_grantable SET NOT NULL;

GRANT ALL ON TABLE
    saved_auths
    TO utils_auth_user;

GRANT ALL ON TABLE
    saved_auths
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON TABLE saved_auths
    IS 'Utility table used for temporary storage of authorizations by save_auth, save_auths, restore_auth and restore_auths';

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

CREATE FUNCTION save_auth(aschema name, atable name)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    WITH data AS (
        SELECT DISTINCT
            grantee,
            privilege_type,
            bool_or(is_grantable::boolean) AS is_grantable
        FROM
            information_schema.table_privileges
        WHERE
            table_catalog = current_database()
            AND table_schema = 'ark_poc'
            AND table_name = 'students'
        GROUP BY
            grantee,
            privilege_type
    ),
    upsert AS (
        UPDATE saved_auths AS dest SET
            is_grantable = src.is_grantable
        FROM
            data AS src
        WHERE
            dest.table_schema = 'ark_poc'
            AND dest.table_name = 'students'
            AND dest.grantee = src.grantee
            AND dest.privilege_type = src.privilege_type
        RETURNING
            src.grantee, src.privilege_type
    )
    INSERT INTO saved_auths (
        table_schema,
        table_name,
        grantee,
        privilege_type,
        is_grantable
    )
    SELECT
        'ark_poc',
        'students',
        grantee,
        privilege_type,
        is_grantable
    FROM
        data
    WHERE
        ROW (grantee, privilege_type) NOT IN (
            SELECT grantee, privilege_type FROM upsert
        );
$$;

CREATE FUNCTION save_auth(atable name)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (save_auth(current_schema, atable));
$$;

GRANT EXECUTE ON FUNCTION
    save_auth(name, name),
    save_auth(name)
    TO utils_auth_user;

GRANT EXECUTE ON FUNCTION
    save_auth(name, name),
    save_auth(name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION save_auth(name, name)
    IS 'Saves the authorizations of the specified relation for later restoration with the RESTORE_AUTH procedure';
COMMENT ON FUNCTION save_auth(name)
    IS 'Saves the authorizations of the specified relation for later restoration with the RESTORE_AUTH procedure';

-- restore_auth(aschema, atable)
-- restore_auth(atable)
-------------------------------------------------------------------------------
-- restore_auth is a utility procedure which restores the authorization
-- privileges for a table or view, previously saved by the save_auth procedure
-- defined above.
--
-- NOTE: Privileges may not be precisely restored. Specifically, the grantor in
-- the restored privileges may be different to the original grantor if you are
-- not the user that originally granted the privileges, or the original
-- privileges were granted by the system. Furthermore, column specific
-- authorizations are NOT saved and restored by these procedures.
-------------------------------------------------------------------------------

CREATE FUNCTION restore_auth(aschema name, atable name)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        WITH data AS (
            DELETE FROM saved_auths
            WHERE
                table_schema = aschema
                AND table_name = atable
            RETURNING grantee, privilege_type, is_grantable
        )
        SELECT
            'GRANT '
            || privilege_type
            || ' ON ' || quote_ident(aschema) || '.' || quote_ident(atable)
            || ' TO ' || quote_ident(grantee)
            || CASE is_grantable WHEN true THEN ' WITH GRANT OPTION' ELSE '' END AS ddl
        FROM
            data
    LOOP
        EXECUTE r.ddl;
    END LOOP;
END;
$$;

CREATE FUNCTION restore_auth(atable name)
    RETURNS void
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (restore_auth(current_schema, atable));
$$;

GRANT EXECUTE ON FUNCTION
    restore_auth(name, name),
    restore_auth(name)
    TO utils_auth_user;

GRANT EXECUTE ON FUNCTION
    restore_auth(name, name),
    restore_auth(name)
    TO utils_auth_admin WITH GRANT OPTION;

COMMENT ON FUNCTION restore_auth(name, name)
    IS 'Restores authorizations previously saved by SAVE_AUTH for the specified table';
COMMENT ON FUNCTION restore_auth(name)
    IS 'Restores authorizations previously saved by SAVE_AUTH for the specified table';

-- vim: set et sw=4 sts=4:
