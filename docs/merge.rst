.. module:: merge

=======================
The ``merge`` Extension
=======================

The merge extension was created to simplify bulk transfers of data between
similarly structured tables. It should be stressed up front that it does *not*,
and is not intended to solve the UPSERT_ problem.

.. _UPSERT: https://wiki.postgresql.org/wiki/UPSERT

Usage
=====

To transfer all rows from one table to another one would traditionally use
SQL similar to the following:

.. code-block:: sql

    INSERT INTO dest
        SELECT * FROM source;

However, when the source and destination are similar but not *exactly* the same
one has to tediously specify all columns involved. The :func:`auto_insert`
function eases this process by taking column names from the destination table
and matching them to columns from the source table by name (regardless of
position). In the following examples we will assume these table definitions:

.. code-block:: sql

    CREATE TABLE contracts_source (
        customer_id     integer NOT NULL,
        contract_id     integer NOT NULL,
        title           varchar(20) NOT NULL,
        plan_cost       decimal(18, 2) NOT NULL,
        plan_revenue    decimal(18, 2) NOT NULL,
        last_updated    timestamp NOT NULL,
        last_updated_by name NOT NULL
    );

    CREATE TABLE contracts_target (
        contract_id     integer NOT NULL,
        customer_id     integer NOT NULL,
        title           varchar(20) NOT NULL,
        plan_cost       decimal(18, 2) NOT NULL,
        plan_revenue    decimal(18, 2) NOT NULL,
        actual_cost     decimal(18, 2) DEFAULT 0.0 NOT NULL,
        actual_revenue  decimal(18, 2) DEFAULT 0.0 NOT NULL,

        PRIMARY KEY (customer_id, contract_id)
    );

The :func:`auto_insert` function can be used with these definitions like so:

.. code-block:: sql

    SELECT auto_insert('contracts_source', 'contracts_target');

This is equivalent to executing the following SQL:

.. code-block:: sql

    INSERT INTO contracts_target (
        customer_id,
        contract_id,
        title,
        plan_cost,
        plan_revenue
    )
    SELECT
        customer_id,
        contract_id,
        title,
        plan_cost,
        plan_revenue
    FROM contracts_source;

Note that columns are matched by name so that even though the order of
``customer_id`` and ``contract_id`` differs between the two tables, they are
ordered correctly in the generated statement. Furthermore, columns that are not
present in both tables are excluded, so ``last_updated`` and
``last_updated_by`` from the source table are ignored while ``actual_cost`` and
``actual_revenue`` will use their default values in the target table.

The similar function :func:`auto_merge` can be used to perform an "upsert" (a
combination of INSERT or UPDATE as appropriate) between two tables. The
function can be used with our example relations like so:

.. code-block:: sql

    SELECT auto_merge('contracts_source', 'contracts_target');

This is equivalent to executing the following SQL:

.. code-block:: sql

    WITH upsert AS (
        UPDATE contracts_target AS dest SET
            plan_cost = src.plan_cost,
            plan_revenue = src.plan_revenue,
            title = src.title
        FROM contracts_source AS src
        WHERE
            src.contract_id = dest.contract_id
            AND src.customer_id = dest.customer_id
        RETURNING
            src.contract_id,
            src.customer_id
    )
    INSERT INTO contracts_target (
        contract_id,
        customer_id,
        plan_cost,
        plan_revenue,
        title
    )
    SELECT
        contract_id,
        customer_id,
        plan_cost,
        plan_revenue,
        title
    FROM contracts_source
    WHERE ROW (contract_id, customer_id) NOT IN (
        SELECT contract_id, customer_id
        FROM upsert
    );

As you can discern from reading the above, this will attempt to execute updates
with each row from source against the target table and, if it fails to find
a matching row (according to the primary key of the target table, by default)
it attempts insertion instead.

Finally, the :func:`auto_delete` function can be used to automatically delete
rows that exist in the target table, that do not exist in the source table:

.. code-block:: sql

    SELECT auto_delete('contracts_source', 'contracts_target');

This is equivalent to executing the following statement:

.. code-block:: sql

    DELETE FROM contracts_target WHERE ROW (contract_id, customer_id) IN (
        SELECT contract_id, customer_id FROM contracts_target
        EXCEPT
        SELECT contract_id, customer_id FROM contracts_source
    )

Use-cases
=========

These routines are designed for use in a data warehouse environment in which
cleansing of incoming data is handled by views within the database.  The
process is intended to work as follows:

1. Data is copied into a set of tables which replicate the structures of their
   source, without any constraints or restrictions. The lack of constraints
   is important to ensure that the source table is replicated perfectly, but
   (non-unique) indexes can be created on these tables to ensure performance
   in the next stages.

2. On top of the source tables, views are created to handle cleaning the data.
   Bear in mind that any INSERT, UPDATE, or DELETE operations can be emulated
   via queries. For example:

    - If you need to INSERT records into the source material, simply UNION ALL
      the source table with the new records (generated via a VALUES statement)

    - If you need to DELETE records from the source material, simply filter
      them out in the WHERE clause (or with a JOIN)

    - If you need to UPDATE records in the source material, change the values
      with transformations in the SELECT clause

3. Finally, the reporting tables are created with the same structure as the
   output of the cleaning views from the step above.

To give a concrete example of this method, consider the examples from above.

API
===

.. function:: auto_insert(source_schema, source_table, dest_schema, dest_table)
              auto_insert(source_table, dest_table)

    :param source_schema: The schema containing the source table. Defaults
        to the current schema if omitted.
    :param source_table: The source table from which to read data.
    :param dest_schema: The schema containing the destination table. Defaults
        to the current schema if omitted.
    :param dest_table: The destination table into which data will be inserted.

.. function:: auto_merge(source_schema, source_table, dest_schema, dest_table, dest_key)
              auto_merge(source_schema, source_table, dest_schema, dest_table)
              auto_merge(source_table, dest_table, dest_key)
              auto_merge(source_table, dest_table)

    :param source_schema: The schema containing the source table. Defaults
        to the current schema if omitted.
    :param source_table: The source table from which to read data.
    :param dest_schema: The schema containing the destination table. Defaults
        to the current schema if omitted.
    :param dest_table: The destination table into which data will be merge.
    :param dest_key: The primary or unique key on the destination table which
        will be used for matching existing records. Defaults to the primary
        key if omitted.

.. function:: auto_delete(source_schema, source_table, dest_schema, dest_table, dest_key)
              auto_delete(source_schema, source_table, dest_schema, dest_table)
              auto_delete(source_table, dest_table, dest_key)
              auto_delete(source_table, dest_table)

    :param source_schema: The schema containing the source table. Defaults
        to the current schema if omitted.
    :param source_table: The source table from which to read data.
    :param dest_schema: The schema containing the destination table. Defaults
        to the current schema if omitted.
    :param dest_table: The destination table from which data will be deleted.
    :param dest_key: The primary or unique key on the destination table which
        will be used for matching existing records. Defaults to the primary
        key if omitted.

