.. _quick_start:

===========
Quick start
===========

This chapter provides a quick walk through of the major functionality available
in the various extensions contained in Oliphant. Each section deals with the
functions of an individual extension.


.. _quick_assert:

``assert`` extension
====================

The functions of the :mod:`assert` extension are primarily intended for the
construction of test suites. Each performs a relatively simple, obvious
function, raising an error in the case of failure. For example, to ensure that
a particular table exists, use :func:`assert_table_exists`::

    CREATE TABLE foo (i integer NOT NULL, PRIMARY KEY);

    SELECT assert_table_exists('foo');

Or to ensure that some value equals another value, use :func:`assert_equals`
(this has overridden variants for all common types)::

    INSERT INTO foo VALUES (1), (2), (3), (4);

    SELECT assert_equals(10, (SELECT SUM(i) FROM foo));

Combined with some cunning catalog queries this can be used for some useful
tests, such as ensuring that the structure of a table is as anticipated::

    CREATE TABLE bar (
        i integer NOT NULL PRIMARY KEY,
        j integer NOT NULL
    );

    SELECT assert_equals(4::bigint, (
        SELECT count(*)
        FROM (
            SELECT attnum, attname
            FROM pg_catalog.pg_attribute
            WHERE attrelid = 'bar'::regclass
            AND attnum > 0

            INTERSECT

            VALUES
                (1, 'i'),
                (2, 'j'),
        ) AS t));

One of the more interesting functions is :func:`assert_raises` which can be
used to check that something produces a specific SQLSTATE::

    SELECT assert_raises('23505', 'INSERT INTO foo VALUES (1)');


.. _quick_auth:

``auth`` extension
==================

The functions of the ``auth`` module are intended for bulk manipulation of role
based authorizations. For example, use :func:`copy_role_auths` to copy all roles
from user1 to user2::

    SELECT copy_role_auths('user1', 'user2');

This will execute the minimum required GRANTs to provide user2 with all roles
that user1 has, which user2 currently does not. Naturally, the caller must have
the necessary authority to execute such GRANTs (thus, usage of this routine is
generally only useful for superusers).

Please note that ownership of objects is *not* transferred by this routine.
That can be easily accomplished with the :ref:`REASSIGN OWNED` statement
instead.

If you wish to move all authorizations from one user to another this can be
accomplished with the similar procedure::

    SELECT move_role_auths('user1', 'user2');

A couple of other procedures can be used to manipulate table authorizations.
To store and restore the authorizations associated with a table::

    SELECT store_table_auths('foo');
    SELECT restore_table_auths('foo');

This may seem pointless in and of itself until you understand that the
authorizations are stored in the ``stored_table_auths`` table which allows you
to manipulate them between storage and restoration. For example, to copy
all authorizations from one table to another::

    SELECT store_table_auths('foo');
    UPDATE stored_table_auths SET table_name = 'bar'
    WHERE table_name = 'foo';
    SELECT restore_table_auths('bar');

Alternatively, to copy only the SELECT privileges::

    SELECT store_table_auths('foo');
    DELETE FROM stored_table_auths
    WHERE table_name = 'foo'
    AND privilege_type <> 'SELECT';
    UPDATE stored_table_auths SET table_name = 'bar'
    WHERE table_name = 'foo';
    SELECT restore_table_auths('bar');

Of course, even without manipulation it can be useful when one wishes to drop
and recreate the table for any reason (e.g. to change the structure in a way
not supported by :ref:`ALTER TABLE`)::

    SELECT store_table_auths('foo');
    DROP TABLE foo;
    CREATE TABLE foo (i integer NOT NULL);
    SELECT restore_table_auths('foo');


.. _quick_merge:

``merge`` extension
===================

.. warning::

    This extension does not, and is not intended to, solve the `UPSERT`_
    problem. It is intended solely for bulk transfers between similarly
    structured relations.

.. _atomic upsert: https://wiki.postgresql.org/wiki/UPSERT

The :func:`auto_insert` function constructs an :ref:`INSERT..SELECT <INSERT>`
statement for every column with the same name in both table1 and table2.
Consider the following example definitions::

    CREATE TABLE table1 (
        i integer NOT NULL PRIMARY KEY,
        j integer NOT NULL,
        k text
    );

    CREATE TABLE table2 (
        i integer NOT NULL PRIMARY KEY,
        j integer NOT NULL,
        k text,
        d timestamp DEFAULT current_timestamp NOT NULL
    );

With these definitions, the following statements are equivalent::

    SELECT auto_insert('table1', 'table2');

    INSERT INTO table2 (i, j, k) SELECT i, j, k FROM table1;

The :func:`auto_merge` function constructs the PostgreSQL equivalent of an
UPSERT or MERGE statement using writeable CTEs. Given the table definitions
above, the following statements are equivalent::

    SELECT auto_merge('table1', 'table2');

    WITH upsert AS (
        UPDATE table2 AS dest SET
            i = src.i,
            j = src.j,
            k = src.k
        FROM table1 AS src
        WHERE src.i = dest.i
        RETURN src.i
    )
    INSERT INTO table2 (i, j, k)
    SELECT i, j, k FROM table1
    WHERE ROW (i) NOT IN (
        SELECT i
        FROM upsert
    );

Finally, the :func:`auto_delete` function is used to remove
all rows from table2 that do not exist in table1. Again, with the table
definitions used above, the following statements are equivalent::

    SELECT auto_delete('table1', 'table2');

    DELETE FROM table2 WHERE ROW (i) IN (
        SELECT i FROM table2
        EXCEPT
        SELECT i FROM table1
    );


.. _quick_history:

``history`` extension
=====================

.. warning::

    It is strongly recommended that you read the full usage chapter on the
    temporal data functions to understand their precise effect and how to query
    and maintain the resulting structures. This section is intended as a brief
    introduction and/or refresher and does not discuss the complexities of
    temporal data at all.

In this section, the following example tables will be used::

    CREATE TABLE employees (
        user_id     integer NOT NULL PRIMARY KEY,
        name        varchar(100) NOT NULL,
        dob         date NOT NULL,
        dept        char(4) NOT NULL,
        is_manager  boolean DEFAULT false NOT NULL,
        salary      numeric(8) NOT NULL
    );

In order to track the history of changes to a particular table, construct
a history table and set of triggers to maintain the content of the history
table. The second parameter in the calls below specifies the resolution of
changes that will be kept (this can be any interval supported by PostgreSQL)::

    SELECT create_history_table('employees', 'day');
    SELECT create_history_triggers('employees', 'day');

The history table will have the same structure as the "base" table (in this
case "employees"), but with the addition of two extra fields: effective and
expiry as the first and second columns respectively. With the "day" resolution,
these columns will have the "date" type. These two columns represent the
inclusive range of dates on which a row was present within the base table.

The history table will initially be populated with the rows from the base
table, with the effective date set to the current date, and expiry set to
9999-12-31 (to indicate each row is "current").

As changes are made to the base table, the history table will be automatically
updated by triggers. To query the state of the base table at a particular
point in time, X, simply use the following query::

    SELECT * FROM employees_history WHERE X BETWEEN effective AND expiry;

To view the changes as a set of insertions, updates, and deletions, along with
the ability to easily see "before" and "after" values for updates, construct a
"changes" view with the following procedure::

    SELECT create_history_changes('employees_history');

The resulting view will be called "employees_changes" by default. It will have
a "changed" column (the date or timestamp) on which the change took place, a
"change" column (containing the string "INSERT", "UPDATE", or "DELETE"
depending on what operation took place), and two columns for each column in the
base table, prefixed with "old_" and "new_" giving the "before" and "after"
values for each column.

For example, to find all rows where an employee received a salary increase::

    SELECT * FROM employees_changes
    WHERE change = 'UPDATE'
    AND new_salary > old_salary;

It is also possible to construct a view which provides snapshots of the base
table over time. This is particularly useful for aggregation queries. For
example::

    SELECT create_history_snapshots('employees_history', 'month');

    SELECT snapshot, dept, count(*) AS monthly_dept_headcount
    FROM employees_by_month
    GROUP BY snapshot, dept;

