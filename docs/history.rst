.. module:: history

=========================
The ``history`` Extension
=========================

The history extension was created to ease the construction and maintenance
of temporal tables; that is tables which track the state of another table over
time. It can be installed and removed in the standard manner:

.. code-block:: sql

    CREATE EXTENSION history;
    DROP EXTENSION history;

It is a relocatable, pure SQL extension which therefore requires no external
libraries or compilation, and consists entirely of user-callable functions.

Usage
=====

To create a history table corresponding to an existing table, use the
:func:`create_history_table` procedure like so:

.. code-block:: sql

    CREATE TABLE employees (
        emp_id          integer NOT NULL PRIMARY KEY,
        name            varchar(100) NOT NULL,
        dob             date NOT NULL,
        dept            char(4) NOT NULL,
        is_manager      boolean DEFAULT false NOT NULL,
        salary          numeric(8) NOT NULL CHECK (salary >= 0)
    );

    SELECT create_history_table('employees', 'day');

Firstly the procedure will create a new table called ``employees_history``
(you can specify a different name with one of the overloaded variants of
the procedure). The new table will have a structure equivalent to executing
the following statement:

.. code-block:: sql

    CREATE TABLE employees_history (
        effective       date NOT NULL DEFAULT current_date,
        expiry          date NOT NULL DEFAULT '9999-12-31'::date,
        emp_id          integer NOT NULL,
        name            varchar(100) NOT NULL,
        dob             date NOT NULL,
        dept            char(4) NOT NULL,
        is_manager      boolean DEFAULT false NOT NULL,
        salary          numeric(8) NOT NULL CHECK (salary >= 0)

        PRIMARY KEY (emp_id, effective),
        UNIQUE (emp_id, expiry),
        CHECK (effective <= expiry)
    );

The structure of the new table is the same as the old with the following
differences:

* Two columns, ``effective`` and ``expiry`` have been inserted at the front
  of the table.
* These two columns have the type ``date`` (this is partially derived from
  the ``'day'`` resolution parameter which will be explained further below)
* All NOT NULL constraints have been copied to the new table.
* Although this is not illustrated in the example above, all CHECK and EXCLUDE
  constraints are copied but for reasons explored below, FOREIGN KEY
  constraints are *not* copied.
* The primary key of the new table is the same as the old table with the
  addition of the new ``effective`` column.
* An additional unique constraint has been created which is equivalent to the
  primary key but with the ``expiry`` column instead.
* An additional CHECK constraint has been created to ensure that ``effective``
  is always less than or equal to ``expiry``.
* Although not shown above, an additional index is created covering just
  ``effective`` and ``expiry`` for performance purposes.
* Although not shown above, all column comments from the base table are copied
  to the history table, and appropriate comments are set for the table itself
  (referencing the base table), and for the new ``effective`` and ``expiry``
  columns.
* Although not shown above, SELECT authorizations for the base table are copied
  to the history table. INSERT, UPDATE, DELETE and TRUNCATE authorizations are
  *not* copied for reasons explained below.

Finally, data is copied from the original table into the new history table
as if the following statement had been executed:

.. code-block:: sql

    INSERT INTO employees_history
        (emp_id, name, dob, dept, is_manager, salary)
        SELECT emp_id, name, dob, dept, is_manager, salary
        FROM employees;

The defaults of the excluded ``effective`` and ``expiry`` columns will set
those fields appropriately during this operation.

This is the first step in creating a functional history table. The next step
is to create the triggers that link the base table to the history table. This
is performed separately for reasons that will be explained below. The procedure
to create these triggers is called as follows:

.. code-block:: sql

    SELECT create_history_triggers('employees', 'day');

This creates four triggers (and their corresponding functions):

* ``employees_insert`` which is triggered upon INSERT operations against
  the ``employees`` table, which inserts new rows into ``employees_history``.
* ``employees_update`` which is triggered upon UPDATE operations against the
  ``employees`` table. This expires the current history row (by changing its
  date from 9999-12-31 to yesterday's date), and inserts a new one with the
  newly updated values (which will have an effective date of today, and an
  expiry date of 9999-12-31).
* ``employees_delete`` which is triggered upon DELETE operations against the
  ``employees`` table. This simply expires the current history row as detailed
  above.
* ``employees_keychg`` which is triggered upon UPDATE of key columns in the
  ``employees`` table. This simply raises an exception; i.e. updates of the
  primary key columns are not permitted in tables which have their history
  tracked (to update the primary key columns you must DELETE the row and
  re-INSERT it with the new key).

The trigger functions are defined as SECURITY DEFINER. Combined with the
exclusion of INSERT, UPDATE, DELETE, and TRUNCATE authorizations this ensures
that the only way (regular) users can update the history table is via the
trigger responding to manipulations of the base table.

It is worth noting that there are a few limitations on which tables can be used
as the basis for a history table:

* Base tables *must* have a primary key.
* The primary key of a base table must be immutable (you may have noticed that
  this will be enforced through the ``keychg`` trigger above).

Querying
--------

The structure of the history table can be understood as follows:

* For each row that currently exists in the base table, an equivalent row will
  exist in the history table with the expiry date set to 9999-12-31 (i.e. in
  the future because it is an extant row).
* For each row that historically existed in the base table, an equivalent row
  will exist in the history table with the effective and expiry dates
  indicating the range of dates between which that row existed in the base
  table.

Therefore, to query the state of the base table at date 2014-01-01 you can
simply use the following query:

.. code-block:: sql

    SELECT emp_id, name, dob, dept, is_manager, salary
    FROM employees_history
    WHERE '2014-01-01' BETWEEN effective AND expiry;

If you have a join to the base table, you can join to the history table in the
same way - just include the criteria above to select the state of the table at
a particular time. For example, assume there exists a table which tracks any
bonuses awarded to employees. We can calculate the amount that the company has
spent on bonuses like so:

.. code-block:: sql

    CREATE TABLE bonuses (
        emp_id          integer NOT NULL,
        awarded_on      date NOT NULL,
        bonus_percent   numeric(4, 1) NOT NULL,

        PRIMARY KEY (emp_id, awarded_on),
        CHECK (bonus_percent BETWEEN 0 AND 100)
    );

    SELECT
        extract(year from b.awarded_on)         AS year,
        sum(e.salary * (b.bonus_percent / 100)) AS annual_bonus_spend
    FROM
        employees_history e
        JOIN bonuses
            ON e.emp_id = b.emp_id
            AND b.awarded_on BETWEEN e.effective AND e.expiry
    GROUP BY
        extract(year from b.awarded_on);

It should be noted that the design of the ``bonuses`` table in the example
above demonstrates an alternative structure for storage of temporal data. This,
and a few other designs will be discussed in the :ref:`design` section below.

While it is easy to query the state of the base table at a given timestamp, it
is harder to see how one could query changes within the history. For example,
which employees have received a salary increase? Usually for this, it is
necessary to self-join the history table so that one can see before and after
states for changes. Creation of such views is automated with the
:func:`create_history_changes` function. We can simply execute:

.. code-block:: sql

    SELECT create_history_changes('employees_history');

This will create a view named ``employees_changes`` with the following
attributes:

* The first column will be named ``changed`` and will contain the timestamp of
  the change that occurred.
* The second column will be named ``change`` and will contain the string
  INSERT, UPDATE, or DELETE indicating which operation was performed.
* The remaining columns are defined as follows: for each column in the base
  table there will be two columns in the view, prefixed with "old\_" and
  "new\_"

In our example above, the view would be defined with the following SQL:

.. code-block:: sql

    CREATE VIEW employees_changes AS
    SELECT
        COALESCE(
            new.effective, old.expiry + '1 day'::interval) AS changed,
        CASE
            WHEN old.emp_id IS NULL AND new.emp_id IS NOT NULL THEN 'INSERT'
            WHEN old.emp_id IS NOT NULL AND new.emp_id IS NOT NULL THEN 'UPDATE'
            WHEN old.emp_id IS NOT NULL AND new.emp_id IS NULL THEN 'DELETE'
            ELSE 'ERROR'
        END AS change,
        old.emp_id AS old_emp_id,
        new.emp_id AS new_emp_id,
        old.name AS old_name,
        new.name AS new_name,
        old.dob AS old_dob,
        new.dob AS new_dob,
        old.dept AS old_dept,
        new.dept AS new_dept,
        old.is_manager AS old_is_manager,
        new.is_manager AS new_is_manager,
        old.salary AS old_salary,
        new.salary AS new_salary
    FROM (
        SELECT *
        FROM employees_history
        WHERE employees_history.expiry < '9999-12-31'
        ) AS old
        FULL JOIN employees_history AS new
            ON (new.effective - '1 day'::interval) >= old.effective
            AND (new.effective - '1 day'::interval) <= old.expiry
            AND old.emp_id = new.emp_id;

With this view it is now a simple matter to determine which employees have
received a salary increase:

.. code-block:: sql

    SELECT *
    FROM employees_changes
    WHERE change = 'UPDATE'
    AND new_salary > old_salary;

Or we can find out who joined and who left during the last year:

.. code-block:: sql

    SELECT *
    FROM employees_changes
    WHERE change IN ('INSERT', 'DELETE')
    AND changed >= CURRENT_DATE - interval '1 year';

Another common use case of history tables is to see the changes in data over
time via regular snapshots. This is also easily accomplished with the
:func:`create_history_snapshots` function which takes the history table and
a resolution (which must be greater than the history table's resolution).
For example, to view the employees table as a series of monthly snapshots:

.. code-block:: sql

    SELECT create_history_snapshots('employees_history', 'month');

This is equivalent to executing the following SQL:

.. code-block:: sql

    CREATE VIEW employees_by_month AS
    WITH RECURSIVE range(at) AS (
        SELECT min(employees_history.effective) AS min
        FROM employees_history

        UNION ALL

        SELECT range.at + interval '1 month'
        FROM range
        WHERE range.at <= current_date
        )
    SELECT
        date_trunc('month', r.at) + interval '1 month' - interval '1 day' AS snapshot,
        h.emp_id,
        h.name,
        h.dob,
        h.dept,
        h.is_manager,
        h.salary
    FROM
        range r
        JOIN employees_history h
            ON r.at >= h.effective AND r.at <= h.expiry;

The resulting view has the same structure as the base table, but with one extra
column at the start: ``snapshot`` which in the case above will contain a date
running from the lowest date in the history to the current date in monthly
increments. If we wished for an employee head-count by month we could simply
use the following query:

.. code-block:: sql

    SELECT snapshot, count(*) AS head_count
    FROM employees_by_month
    GROUP BY snapshot;

Or we could find out the employee headcount and salary costs broken down by
month and managerial status:

.. code-block:: sql

    SELECT
        snapshot,
        is_manager,
        count(*) AS head_count,
        sum(salary) AS salary_costs
    FROM employees_by_month
    GROUP BY snapshot, is_manager;

Note that because this view relies on a recursive CTE its performance may
suffer with large date ranges. In such cases you may wish to materialise the
view and index relevant columns.

.. _design:

Design
------

This section discusses the various ways in which one can represent temporal
data and attempts to justify the design that this particular extension uses.
The first naïve attempts to track the history of a table typically look like
this (assuming the structure of the ``employees`` table from the usage
section above):

.. code-block:: sql

    CREATE TABLE employees (
        changed         date NOT NULL,
        emp_id          integer NOT NULL,
        name            varchar(100) NOT NULL,
        dob             date NOT NULL,
        dept            char(4) NOT NULL,
        is_manager      boolean DEFAULT false NOT NULL,
        salary          numeric(8) NOT NULL CHECK (salary >= 0),

        PRIMARY KEY (changed, emp_id)
    );

Now let's place some sample data in here; the addition of three employees
sometime in 2007:

.. code-block:: sql

    INSERT INTO employees VALUES
        ('2007-07-06', 1, 'Tom',   '1976-01-01', 'D001', false, 40000),
        ('2007-07-07', 2, 'Dick',  '1980-03-31', 'D001', true,  80000),
        ('2007-07-01', 3, 'Harry', '1977-12-25', 'D002', false, 35000);

Now later in 2007, Harry gets a promotion to manager, and Dick changes his name
to Richard:

.. code-block:: sql

    INSERT INTO employees VALUES
        ('2007-10-01', 3, 'Harry',   '1977-12-25', 'D002', true, 70000),
        ('2007-10-01', 2, 'Richard', '1980-03-31', 'D001', true, 80000);

At this point we can see that the table is tracking the history of the
employees, and we can write relatively simple queries to answer questions about
the data.  For example, when did Harry get his promotion?

.. code-block:: sql

    SELECT min(changed)
    FROM employees
    WHERE emp_id = 3
    AND salary = 80000;

However, other questions are more difficult to answer with this structure.
What was Harry's salary immediately before his promotion?

.. code-block:: sql

    SELECT salary
    FROM employees e1
    WHERE emp_id = 3
    AND changed = (
        SELECT max(changed)
        FROM employees e2
        WHERE e1.emp_id = e2.emp_id
        AND e2.salary <> 80000
        );

Furthermore, some questions are impossible to answer because one particular
operation is not represented in this structure: deletion. Because there's no
specific representation for deletion we can't tell the difference between an
update and a deletion followed by later re-insertion (with the same key).

This is why *two* dates are required in the history table (or more precisely a
date or timestamp *range*). Alternatively we could do something similar to the
view produced by :func:`create_history_snapshots` and place a copy of all the
data in the table for every single day that passes. That way the absence of a
key on a given day would indicate deletion. Obviously this method is extremely
wasteful of space, and thus very slow in practice.

Another alternative, similar to the view produced by
:func:`create_history_changes` is to add another field indicating the change
that occurred, e.g.:

.. code-block:: sql

    CREATE TABLE employees (
        changed         date NOT NULL,
        change          char(6) NOT NULL,
        emp_id          integer NOT NULL,
        name            varchar(100) NOT NULL,
        dob             date NOT NULL,
        dept            char(4) NOT NULL,
        is_manager      boolean DEFAULT false NOT NULL,
        salary          numeric(8) NOT NULL CHECK (salary >= 0),

        PRIMARY KEY (changed, emp_id),
        CHECK (change IN ('INSERT', 'UPDATE', 'DELETE'))
    );

Note that without the duplication of fields for before and after values, this
makes the structure more space efficient but actually makes querying it very
difficult for certain questions. Furthermore, it's quite difficult to transform
this structure into the date-range structure required to answer the question
"what did the table look like at time X?".

Hopefully the above exploration of alternate structures has convinced you that
the simplest, most flexible, and most space efficient representation of
temporal data is the date-range structure used by the functions in this
extension. It is worth noting that in all implementations of temporal data
storage that the author is aware of (DB2's time travel queries, Teradata's
T-SQL2 implementation, and Oracle's flashback queries) date ranges are used in
the underlying storage.

The following sections summarize the advantages and disadvantages of the
design of this particular temporal data implementation.

.. _design_pros:

Advantages
----------

* Simplicity: because the base table is not altered in any way, no operations
  against that table need to change. Nor do any views that rely on that table,
  or any APIs that reference it.

* Security: as a separate table is used to store the history, and that table is
  not directly manipulable by users, the history can be "trusted" to a greater
  degree than a system which relies upon a single table or one in which the
  users can directly manipulate the history table.

* Performance and space: the date-range representation of temporal data is
  (almost) minimal compared to other designs.

* Performance and space: this system provides a wide variety of resolutions for
  the history table and triggers. In the case that every single update does not
  need to be kept (and generally this is not a requirement for many reporting
  databases) this permits one to keep a minimal history to maintain
  performance.

.. _design_cons:

Disadvantages
-------------

* Performance: naturally all operations against the base table will take longer
  with the triggers and history table in place (simply because more work is
  being done for each operation). Furthermore, performance degradation will
  gradually increase the larger the history table gets (as each operation will
  involve a lookup in a larger and larger index). Administrators are encouraged
  to keep an eye on operational performance over time and implement archiving
  when necessary.

* Space: the history table is not a perfectly minimal representation of the
  history.  Certain combinations of operations, in particular removing and
  inserting the same set of rows from the base table repeatedly, result in an
  extremely bloated history table (containing many contiguous rows representing
  the same state).  Furthermore, it can be argued that the current row in the
  history table is a redundant duplicate of the equivalent row in the base
  table, which also wastes space. Whilst this is true, the alternative
  (performing a union of the base and history tables each time a temporal query
  is required) introduces considerable complexity.

API
===

.. function:: create_history_table(source_schema, source_table, dest_schema, dest_table, dest_tbspace, resolution)
              create_history_table(source_table, dest_table, dest_tbspace, resolution)
              create_history_table(source_table, dest_table, resolution)
              create_history_table(source_table, resolution)

    :param source_schema: The schema containing the base table. Defaults to
        the current schema if omitted.
    :param source_table: The table to use as a basis for the history table.
    :param dest_schema: The schema that the history table is to be created in.
        Defaults to the current schema if omitted.
    :param dest_table: The name of the history table. Defaults to the name of
        the source table with the suffix ``_history`` if omitted.
    :param dest_tbspace: The tablespace in which to create the history table.
        Defaults to the tablespace of the source table if omitted.
    :param resolution: The resolution of the history that is to be stored,
        e.g. 'day', 'microsecond', 'hour', 'week', etc.

.. function:: create_history_triggers(source_schema, source_table, dest_schema, dest_table, resolution, offset)
              create_history_triggers(source_table, dest_table, resolution, offset)
              create_history_triggers(source_table, resolution, offset)
              create_history_triggers(source_table, resolution)

    :param source_schema: The schema containing the base table. Defaults to
        the current schema if omitted.
    :param source_table: The table to use as a basis for the history table.
    :param dest_schema: The schema that the history table is to be created in.
        Defaults to the current schema if omitted.
    :param dest_table: The name of the history table. Defaults to the name of
        the source table with the suffix ``_history`` if omitted.
    :param resolution: The resolution of the history that is to be stored,
        e.g. 'day', 'microsecond', 'hour', 'week', etc.
    :param offset: An interval which specifies an offset to apply to all
        timestamps recorded in the history table. Defaults to no offset if
        omitted.

.. function:: create_history_changes(source_schema, source_table, dest_schema, dest_view)
              create_history_changes(source_table, dest_view)
              create_history_changes(source_table)

    :param source_schema: The schema containing the history table. Defaults
        to the current schema if omitted.
    :param source_table: The history table on which to base the changes view.
    :param dest_schema: The schema in which to create the changes view.
        Defaults to the current schema if omitted.
    :param dest_view: The name of the new changes view. Defaults to the
        history table's name with ``_history`` replaced with ``_changes``.

.. function:: create_history_snapshots(source_schema, source_table, dest_schema, dest_view, resolution)
              create_history_snapshots(source_table, dest_view, resolution)
              create_history_snapshots(source_table, resolution)

    :param source_schema: The schema containing the history table. Defaults to
        the current schema if omitted.
    :param source_table: The history table on which to base the snapshots view.
    :param dest_schema: The schema in which to create the snapshots view.
        Defaults to the current schema if omitted.
    :param dest_view: The name of the new snapshots view. Defaults to the
        history table's name with ``_history`` replaced with ``_by_`` and the
        resolution.
    :param resolution: The resolution of the snapshots to be generated in the
        view. This must be longer than the resolution of the history table.

