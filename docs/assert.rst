.. module:: assert

========================
The ``assert`` Extension
========================

The assert extension grew out of a desire to construct a test suite using SQL
statements alone. It can be installed and removed in the standard manner:

.. code-block:: sql

    CREATE EXTENSION assert;
    DROP EXTENSION assert;

It is a relocatable, pure SQL extension which therefore requires no external
libraries or compilation, and consists entirely of user-callable functions.

Usage
=====

The most basic routines in the extension are :func:`assert_is_null` and
:func:`assert_is_not_null` which test whether the given value is or is not NULL
respectively, raising SQLSTATEs UTA06 and UTA07 respectively. These functions
have two overloaded variants, one using the polymorphic ``anyelement`` type and
the other ``text`` which should cover the vast majority of use cases:

.. code-block:: psql

    db=# SELECT assert_is_null(null::date);
     assert_is_null
    ----------------

    (1 row)

    db=# SELECT assert_is_null('');
    ERROR:   is not NULL
    db=# SELECT assert_is_null(1);
    ERROR:  1 is not NULL

Similarly, :func:`assert_equals` and :func:`assert_not_equals` test whether the
two provided values are equal or not. If the assertion fails, SQLSTATE UTA08 is
raised by :func:`assert_equals` and UTA09 by :func:`assert_not_equals`. Again,
two overloaded variants exist to cover all necessary types:

.. code-block:: psql

    db=# SELECT assert_equals(1, 1);
     assert_equals
    ---------------

    (1 row)

    db=# SELECT assert_equals('foo', 'bar');
    ERROR:  foo does not equal bar

A set of functions for asserting the existing of various structures are also
provided: :func:`assert_table_exists` (which works for any relation-like
structure such as tables and views), :func:`assert_column_exists` (for testing
individual columns within a relation), :func:`assert_function_exists`, and
:func:`assert_trigger_exists`:

.. code-block:: psql

    db=# CREATE TABLE foo (i integer NOT NULL);
    CREATE TABLE
    db=# SELECT assert_table_exists('foo');
     assert_table_exists
    ---------------------

    (1 row)

    db=# SELECT assert_table_exists('bar');
    ERROR:  Table public.bar does not exist
    CONTEXT:  SQL function "assert_table_exists" statement 1
    db=# SELECT assert_column_exists('foo', 'i');
     assert_column_exists
    ----------------------

    (1 row)

Note that with a bit of querying knowledge, it is actually more efficient to
test a whole table structure using :func:`assert_equals`. For example:

.. code-block:: sql

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

Naturally, one could extend this technique to include tests for the column
types, nullability, etc.

Finally, the :func:`assert_raises` function can be used to test whether
arbitrary SQL raises an expected SQLSTATE. This is especially useful when
building test suites for extensions (naturally, this function is used
extensively within the test suite for the :mod:`assert` extension!):

.. code-block:: psql

    db=# SELECT assert_raises('UTA08', 'SELECT assert_equals(1, 2)');
     assert_raises
    ---------------

    (1 row)

    db=# SELECT assert_raises('UTA08', 'SELECT assert_equals(1, 1)');
    ERROR:  SELECT assert_equals(1, 1) did not signal SQLSTATE UTA08

API
===

.. function:: assert_equals(a, b)

    :param a: The first value to compare
    :param b: The second value to compare

    Raises SQLSTATE 'UTA08' if *a* and *b* are not equal. If either *a* or *b*
    are NULL, the assertion will succeed (no exception will be raised). See
    :func:`assert_is_null` for this instead.

.. function:: assert_not_equals(a, b)

    :param a: The first value to compare
    :param b: The second value to compare

    Raises SQLSTATE 'UTA09' if *a* and *b* are equal. If either *a* or *b* are
    NULL, the assertion will succeed (no exception will be raised). See
    :func:`assert_is_null` for this instead.

.. function:: assert_is_null(a)

    :param a: The value to test

    Raises SQLSTATE 'UTA06' if *a* is not NULL.

.. function:: assert_is_not_null(a)

    :param a: The value to test

    Raises SQLSTATE 'UTA07' if *a* is NULL.

.. function:: assert_table_exists(aschema, atable)
              assert_table_exists(atable)

    :param aschema: The schema containing the table to test
    :param atable: The table to test for existence

    Tests whether the table named *atable* within the schema *aschema* exists.
    If *aschema* is omitted it defaults to the current schema. Raises SQLSTATE
    'UTA02' if the table does not exist.

.. function:: assert_column_exists(aschema, atable, acolumn)
              assert_column_exists(atable, acolumn)

    :param aschema: The schema containing the table to test
    :param atable: The table containing the column to test
    :param acolumn: The column to test for existence

    Tests whether the column named *acolumn* exists in the table identified
    by *aschema* and *atable*. If *aschema* is omitted it defaults to the
    current schema. Raises SQLSTATE 'UTA03' if the column does not exist.

.. function:: assert_trigger_exists(aschema, atable, atrigger)
              assert_trigger_exists(atable, atrigger)

    :param aschema: The schema containing the table to test
    :param atable: The table containing the column to test
    :param atrigger: The trigger to test for existence

    Tests whether the trigger named *atrigger* exists for the table identified
    by *aschema* and *atable*. If *aschema* is omitted it defaults to the
    current schema. Raises SQLSTATE 'UTA04' if the column does not exist.

.. function:: assert_function_exists(aschema, atable, argtypes)
              assert_function_exists(atable, argtypes)

    :param aschema: The schema containing the function to test
    :param atable: The table to test for existence
    :param argtypes: An array of type names to match against the parameters of
        the function

    Tests whether the function named *afunction* with the parameter types given
    by the array *argtypes* exists within the schema *aschema*. If *aschema*
    is omitted it defaults to the current schema. Raises SQLSTATE 'UTA05' if
    the table does not exist.

.. function:: assert_raises(state, sql)

    :param state: The SQLSTATE to test for
    :param sql: The SQL to execute to test if it fails correctly

    Tests whether the execution of the statement in *sql* results in the
    SQLSTATE *state* being raised. Raises SQLSTATE UTA01 in the event that
    *state* is not raised, or that a different SQLSTATE is raised.

