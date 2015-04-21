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

    CREATE TABLE contracts_clean (
        customer_id     integer NOT NULL,
        contract_id     integer NOT NULL,
        title           varchar(20) NOT NULL,
        plan_cost       decimal(18, 2) DEFAULT NULL,
        plan_revenue    decimal(18, 2) DEFAULT NULL,
        last_updated    timestamp NOT NULL,
        last_updated_by name NOT NULL
    );

    CREATE TABLE contracts (
        contract_id     integer NOT NULL,
        customer_id     integer NOT NULL,
        title           varchar(20) NOT NULL,
        plan_cost       decimal(18, 2) DEFAULT NULL,
        plan_revenue    decimal(18, 2) DEFAULT NULL,
        actual_cost     decimal(18, 2) DEFAULT 0.0 NOT NULL,
        actual_revenue  decimal(18, 2) DEFAULT 0.0 NOT NULL,

        PRIMARY KEY (customer_id, contract_id)
    );

The :func:`auto_insert` function can be used with these definitions like so:

.. code-block:: sql

    SELECT auto_insert('contracts_clean', 'contracts');

This is equivalent to executing the following SQL:

.. code-block:: sql

    INSERT INTO contracts (
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
    FROM contracts_clean;

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

    SELECT auto_merge('contracts_clean', 'contracts');

This is equivalent to executing the following SQL:

.. code-block:: sql

    WITH upsert AS (
        UPDATE contracts AS dest SET
            plan_cost = src.plan_cost,
            plan_revenue = src.plan_revenue,
            title = src.title
        FROM contracts_clean AS src
        WHERE
            src.contract_id = dest.contract_id
            AND src.customer_id = dest.customer_id
        RETURNING
            src.contract_id,
            src.customer_id
    )
    INSERT INTO contracts (
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
    FROM contracts_clean
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

    SELECT auto_delete('contracts_clean', 'contracts');

This is equivalent to executing the following statement:

.. code-block:: sql

    DELETE FROM contracts WHERE ROW (contract_id, customer_id) IN (
        SELECT contract_id, customer_id FROM contracts
        EXCEPT
        SELECT contract_id, customer_id FROM contracts_clean
    )

Use-cases
=========

These routines are designed for use in a database environment in which
cleansing of incoming data is handled by views within the database. The process
is intended to work as follows:

1. Data is copied into a set of tables which replicate the structures of their
   source, without any constraints or restrictions. The lack of constraints is
   important to ensure that the source data is represented accurately,
   imperfections and all. However, non-unique indexes can be created on these
   tables to ensure performance in the next stages.

2. On top of the source tables, views are created to handle cleaning the data.
   Bear in mind that transformation of data (by INSERT, UPDATE, or DELETE
   operations) can be accomplished via queries. For example:

    - If you need to INSERT records into the source material, simply UNION ALL
      the source table with the new records (generated via a VALUES statement)

    - If you need to DELETE records from the source material, simply filter
      them out in the WHERE clause (or with a JOIN)

    - If you need to UPDATE records in the source material, change the values
      with transformations in the SELECT clause

3. Finally, the reporting tables are created with the same structure as the
   output of the cleaning views from the step above.

To give a concrete example of this method, consider the examples from above.
Let us assume that the source of the contracts data is a CSV file periodically
refreshed by some process (this probably sounds awful, and it is, but I've seen
worse in practice). We would represent this source data with a table like so:

.. code-block:: sql

    CREATE TABLE contracts_raw (
        customer_id     text NOT NULL,
        contract_id     text NOT NULL,
        title           text NOT NULL,
        plan_cost       text NOT NULL,
        plan_revenue    text NOT NULL,
        last_updated    text NOT NULL,
        last_updated_by text NOT NULL
    );

Note the use of text fields as we've no guarantee that any of the CSV data is
actually well structured and we want to ensure that it is loaded successfully
(even if subsequent cleaning fails) so that we have a copy of the source data
to debug within the database (this is much easier than relying on external
files for debugging).

Now we'd construct the ``contracts_clean`` table as a view on top of this:

.. code-block:: sql

    DROP TABLE contracts_clean;
    CREATE VIEW contracts_clean AS
        SELECT
            b.customer_id::int,
            b.contract_id::int,
            b.title::varchar(20),
            CASE
                WHEN b.plan_cost    ~ '^[0-9]{0,16}\.[0-9]{2}$' THEN b.plan_cost
            END::decimal(18, 2) AS plan_cost,
            CASE
                WHEN b.plan_revenue ~ '^[0-9]{0,16}\.[0-9]{2}$' THEN b.plan_revenue
            END::decimal(18, 2) AS plan_revenue,
            b.last_updated::timestamp,
            b.last_updated_by::name
        FROM
            contracts_base b
            JOIN customers c
                ON b.customer_id::int = c.customer_id
        WHERE b.contract_id::int > 0;

The view performs the following operations:

* Casts are used to convert the text from the CSV into the correct data-type.
  In certain cases, CASE expressions with regexes are used to guard against
  "known bad" data, but in others an error will occur if the source data
  is incorrect (this is deliberate, under the theory that it is better to
  fail loudly than silently produced incorrect results).

* A JOIN on a customers table ensures any rows with invalid customer numbers
  are excluded; if we wished to include them we could use an OUTER JOIN, and
  make up an "invalid customer" customer to substitute in such cases (if
  ``customer_id`` weren't part of the primary key we could simply use the OUTER
  JOIN and accept the NULL in cases of invalid customer numbers).

* A WHERE clause excludes any negative or zero contract IDs (presumably these
  occur in the source and are not wanted).

Now we can load data into our final ``contracts`` table, with all data cleaning
performed in SQL as follows:

.. code-block:: psql

    COPY contracts_raw FROM 'contracts.csv' WITH (FORMAT csv);
    SELECT auto_merge('contracts_clean', 'contracts');
    SELECT auto_delete('contracts_clean', 'contracts');

Why are the merge and delete functions provided separately? Consider the case
where our contracts table has a foreign key to the customers table we
referenced above:

.. code-block:: sql

    CREATE TABLE contracts (
        contract_id     integer NOT NULL,
        customer_id     integer NOT NULL,
        title           varchar(20) NOT NULL,
        plan_cost       decimal(18, 2) DEFAULT NULL,
        plan_revenue    decimal(18, 2) DEFAULT NULL,
        actual_cost     decimal(18, 2) DEFAULT 0.0 NOT NULL,
        actual_revenue  decimal(18, 2) DEFAULT 0.0 NOT NULL,

        PRIMARY KEY (customer_id, contract_id),
        FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
            ON DELETE RESTRICT
    );

In this case we have to ensure that new customers are inserted before contracts
is updated (in case any contracts reference the new customers) but we must also
ensure that old customers are only deleted *after* contracts has been updated
(in case any existing contracts reference the old customers). Assuming
customers had a similar setup (a table to hold the raw source data, a view to
clean the raw data, and a final table to contain the cleaned data), in this
case our loading script might look something like this:

.. code-block:: psql

    COPY contracts_raw FROM 'contracts.csv' WITH (FORMAT csv);
    COPY customers_raw FROM 'customers.csv' WITH (FORMAT csv);

    SELECT auto_merge('customers_clean', 'customers');
    SELECT auto_merge('contracts_clean', 'contracts');
    SELECT auto_delete('contracts_clean', 'contracts');
    SELECT auto_delete('customers_clean', 'customers');

As a general rule, given a hierarchy of tables with foreign keys between them,
merge from the top of the hierarchy down to the bottom, then delete from the
bottom of the hierarchy back up to the top.

Why bother with a merge function at all? Why not truncate and re-write the
target table each time? In the case of small to medium sized tables this may be
a perfectly realistic option in terms of performance (it may even lead to
better performance in some circumstances). In the case of large tables,
obviously it pays to do as little IO as possible and therefore merging is
usually preferable (on the assumption that most of the data doesn't change that
much).

However, there is another more subtle reason to consider. By merging we are
accurately telling the database engine what happened to each record: whether
it was inserted, updated or deleted at the source. If we truncated and re-wrote
the whole table such information would be lost. In turn this allows us to
accurately use the :mod:`history` extension to keep a history of our customers
and contracts tables. We could simply execute the following statements:

.. code-block:: sql

    SELECT create_history_table('customers', 'day');
    SELECT create_history_table('contracts', 'day');
    SELECT create_history_triggers('customers', 'day');
    SELECT create_history_triggers('contracts', 'day');

Now every time the customers and contracts tables are loaded with our script
above, the history is updated too and we can show the state of these tables for
any day in the past.

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

    Inserts rows from the table named by *source_schema* and *source_table*
    into the table named by *target_schema* and *target_table*. The schema
    parameters can be omitted in which case they will default to the current
    schema.

    Columns of the two tables will be matched by name, *not* by position. Any
    columns that do not occur in both tables will be omitted (if said columns
    occur in the target table, the defaults of those columns will be used on
    insertion). The source table may also be a view.

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

    Merges rows from the table identified by *source_schema* and *source_table*
    into the table identified by *target_schema* and *target_table*, based on
    the primary or unique key of the target table named by *dest_key*. If the
    schema parameters are omitted they default to the current schema. If the
    *dest_key* parameter is omitted it defaults to the name of the primary key
    of the target table.

    Columns of the two tables will be matched by name, *not* by position. Any
    columns that do not occur in both tables will be omitted from updates or
    inserts. However, all columns specified in *dest_key* must also exist in
    the source table.

    If a row from the source table already exists in the target table, it will
    be updated with the non-key attributes of that row in the source table.
    Otherwise, it will be inserted into the target table.

    .. warning::

        This function is intended for bulk transfer between similarly
        structured relations. It does not solve the concurrency issues required
        by those looking for atomic upsert functionality.

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

    Removes rows from the table identified by *target_schema* and
    *target_table* if those rows do not also exist in the table identified by
    *source_schema* and *source_table*, based on the primary or unique key of
    the target table named by *dest_key*. If the schema parameters are omitted
    they default to the current schema. If the *dest_key* parameter is omitted
    it defaults to the primary key of the target table.

    Columns of the two tables will be matched by name, *not* by position.  All
    columns specified in *dest_key* must exist in the source table.

