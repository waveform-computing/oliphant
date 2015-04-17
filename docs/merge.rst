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
        last_updated    timestamp NOT NULL
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

