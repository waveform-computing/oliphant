-------------------------------------------------------------------------------
-- POSTGRESQL UTILITIES
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
-- This module provides the package-wide roles that inherit all privileges from
-- the module-specific roles defined by the other .sql files.
-------------------------------------------------------------------------------

CREATE SCHEMA %SCHEMANAME%;

SET search_path TO %SCHEMANAME%;

CREATE ROLE utils_user;
CREATE ROLE utils_admin;

GRANT USAGE ON SCHEMA %SCHEMANAME% TO utils_user;
GRANT ALL ON SCHEMA %SCHEMANAME% TO utils_admin WITH GRANT OPTION;

CREATE FUNCTION table_oid(aschema name, atable name)
    RETURNS regclass
    LANGUAGE SQL
    STABLE
AS $$
    VALUES ((quote_ident(aschema) || '.' || quote_ident(atable))::regclass);
$$;

CREATE FUNCTION function_oid(aschema name, afunction name, argtypes name[])
    RETURNS regprocedure
    LANGUAGE SQL
    STABLE
AS $$
    -- XXX This assumes that unnest returns elements from the array in order...
    SELECT
        (quote_ident(aschema) || '.' || quote_ident(afunction) || '(' || string_agg(t.n, ',') || ')')::regprocedure
    FROM
        unnest(argtypes) AS t(n);
$$;
