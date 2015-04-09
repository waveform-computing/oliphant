.. _assert:

========================
The ``assert`` Extension
========================

The assert extension grew out of a desire to construct a test suite using SQL
statements alone. It can be installed and removed in the standard manner::

    CREATE EXTENSION assert;
    DROP EXTENSION assert;

It is a relocatable, pure SQL extension which therefore requires no external
libraries or compilation, and consists entirely of user-callable functions.

The most basic routines in the extension are :func:`assert_is_null` and
:func:`assert_is_not_null` which test whether the given value is or is not NULL
respectively, raising SQLSTATEs UTA06 and UTA07 respectively. These functions
have two overloaded variants, one using the polymorphic ``anyelement`` type and
the other ``text`` which should cover the vast majority of use cases::

    dave=# SELECT assert_is_null(null::date);
     assert_is_null
    ----------------

    (1 row)

    dave=# SELECT assert_is_null('');
    ERROR:   is not NULL
    dave=# SELECT assert_is_null(1);
    ERROR:  1 is not NULL

Similarly, :func:`assert_equals` and :func:`assert_not_equals` test whether the
two provided values are equal or not. If the assertion fails, SQLSTATE UTA08 is
raised by :func:`assert_equals` and UTA09 by :func:`assert_not_equals`. Again,
two overloaded variants exist to cover all necessary types::

    dave=# SELECT assert_equals(1, 1);
     assert_equals
    ---------------

    (1 row)

    dave=# SELECT assert_equals('foo', 'bar');
    ERROR:  foo does not equal bar

A set of functions for asserting the existing of various structures are also
provided: :func:`assert_table_exists` (which works for any relation-like
structure such as tables and views), :func:`assert_column_exists` (for testing
individual columns within a relation), :func:`assert_function_exists`, and
:func:`assert_trigger_exists`::

    dave=# CREATE TABLE foo (i integer NOT NULL);
    CREATE TABLE
    dave=# SELECT assert_table_exists('foo');
     assert_table_exists
    ---------------------

    (1 row)

    dave=# SELECT assert_table_exists('bar');
    ERROR:  Table public.bar does not exist
    CONTEXT:  SQL function "assert_table_exists" statement 1

