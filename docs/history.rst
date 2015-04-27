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

.. _history_setup:

Setup
=====

To create a history table corresponding to an existing table, first set up your
base tables as normal. The examples in this section will be using the following
table definitions:

.. code-block:: sql

    CREATE TABLE departments (
        dept_id         char(4) NOT NULL PRIMARY KEY,
        name            varchar(100) NOT NULL
    );

    CREATE TABLE employees (
        emp_id          integer NOT NULL PRIMARY KEY,
        name            varchar(100) NOT NULL,
        dob             date NOT NULL,
        dept_id         char(4) NOT NULL REFERENCES departments(dept_id),
        is_manager      boolean DEFAULT false NOT NULL,
        salary          numeric(8) NOT NULL CHECK (salary >= 0)
    );

    COMMENT ON TABLE employees IS 'The set of people currently employed by the company';
    COMMENT ON COLUMN employees.emp_id     IS 'The unique identifier of the employee';
    COMMENT ON COLUMN employees.name       IS 'The full name of the employee';
    COMMENT ON COLUMN employees.dob        IS 'The date of birth of the employee';
    COMMENT ON COLUMN employees.dept_id    IS 'The department the employee belongs to';
    COMMENT ON COLUMN employees.is_manager IS 'True if the employee manages others';
    COMMENT ON COLUMN employees.salary     IS 'The base annual salary of the employee in US dollars';

    GRANT SELECT, INSERT, UPDATE, DELETE ON employees TO dir_manager;
    GRANT SELECT ON employees TO dir_web_intf;

Then, use the :func:`create_history_table` function like so:

.. code-block:: psql

    db=# select create_history_table('employees', 'day');
     create_history_table
    ----------------------

    (1 row)

The procedure will create a new table called ``employees_history`` (you can
specify a different name with one of the overloaded variants of the procedure).
The new table will have a structure equivalent to executing the following
statements:

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

    CREATE INDEX employees_history_ix2 ON
        employees_history (effective, expiry);

    COMMENT ON TABLE employees_history IS 'History table which tracks the content of @public.employees';
    COMMENT ON COLUMN employees_history.effective  IS 'The date/timestamp from which this row was present in the source table';
    COMMENT ON COLUMN employees_history.expiry     IS 'The date/timestamp until which this row was present in the source table (rows with 9999-12-31 currently exist in the source table)';
    COMMENT ON COLUMN employees_history.emp_id     IS 'The unique identifier of the employee';
    COMMENT ON COLUMN employees_history.name       IS 'The full name of the employee';
    COMMENT ON COLUMN employees_history.dob        IS 'The date of birth of the employee';
    COMMENT ON COLUMN employees_history.dept       IS 'The department the employee belongs to';
    COMMENT ON COLUMN employees_history.is_manager IS 'True if the employee manages others';
    COMMENT ON COLUMN employees_history.salary     IS 'The base annual salary of the employee in US dollars';

    GRANT SELECT ON employees_history TO dir_manager;
    GRANT SELECT ON employees_history TO dir_web_intf;

    INSERT INTO employees_history
        (emp_id, name, dob, dept, is_manager, salary)
        SELECT emp_id, name, dob, dept, is_manager, salary
        FROM employees;

The structure of the new table is the same as the old with the following
differences:

* Two columns, ``effective`` and ``expiry`` have been inserted at the front
  of the table.
* These two columns have the type ``date`` (this is partially derived from
  the ``'day'`` resolution parameter which will be explained further below)
* All NOT NULL constraints have been copied to the new table.
* All CHECK and EXCLUDE constraints are copied but for reasons explored below,
  FOREIGN KEY constraints are *not* copied.
* The primary key of the new table is the same as the old table with the
  addition of the new ``effective`` column.
* An additional unique constraint has been created which is equivalent to the
  primary key but with the ``expiry`` column instead.
* An additional CHECK constraint has been created to ensure that ``effective``
  is always less than or equal to ``expiry``.
* An additional index is created covering just ``effective`` and ``expiry`` for
  performance purposes.
* All column comments from the base table are copied to the history table, and
  appropriate comments are set for the table itself (referencing the base
  table), and for the new ``effective`` and ``expiry`` columns.
* SELECT authorizations for the base table are copied to the history table.
  INSERT, UPDATE, DELETE and TRUNCATE authorizations are *not* copied for
  reasons explained below.
* Finally, data is copied from the original table into the new history table.
  The defaults of the excluded ``effective`` and ``expiry`` columns will set
  those fields appropriately during this operation.

This completes the first step in creating a functional history table. The
reason that FOREIGN KEY constraints are excluded from duplication on the
history table is that there is no good way to enforce them upon history rows.
Consider the scenario where an employee used to be a member of a department
which is removed. The history table must represent that the employee used to
belong to this department, but the parent row no longer exists in the
departments table.

Even if we also applied a history to the departments table, a simple equality
lookup (which is all that foreign keys support) is insufficient to find the
parent row; as demonstrated in the :ref:`history_querying` section below an,
inequality is required.

The second, and final, step is to create the triggers that link the base table
to the history table. This is performed separately for reasons that will be
explained below. The procedure to create these triggers is called as follows:

.. code-block:: psql

    db=# select create_history_triggers('employees', 'day');
     create_history_triggers
    -------------------------

    (1 row)

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
exclusion of INSERT, UPDATE, DELETE, and TRUNCATE authorizations (see action
list above) this ensures that the only way (regular) users can update the
history table is via the trigger responding to manipulations of the base table.

If you have existing history records that you wish to load into the history
table, this should be done before the creation of history triggers. See below
for more information on the structure and behaviour of the history table.

Resolution
----------

The last parameter when creating both the table and triggers is the resolution
to use in the resulting structures. So far, we have used ``'day'`` but any of
the following resolutions are valid:

* ``'microsecond'``
* ``'millisecond'``
* ``'second'``
* ``'minute'``
* ``'hour'``
* ``'day'``
* ``'week'``
* ``'month'``
* ``'quarter'``
* ``'year'``
* ``'decade'``
* ``'century'``
* ``'millennium'``

The resolution affects how many changes are kept in the history table. With
the ``'day'`` resolution, only the final state of a record in a given day
will be stored in the history table. For example, if a row is inserted into
the base table, it will also appear in the history table:

.. code-block:: psql

    db=# insert into departments values ('SR01', 'Slate Rock and Gravel dept 01');
    INSERT 0 1
    db=# insert into employees values (1, 'Fred Flintstone', '1960-07-05', 'SR01', false, 10000.0);
    INSERT 0 1
    db=# select * from employees_history;
     effective  |   expiry   | emp_id |      name       |    dob     | dept_id | is_manager | salary
    ------------+------------+--------+-----------------+------------+---------+------------+--------
     2015-04-23 | 9999-12-31 |      1 | Fred Flintstone | 1960-07-05 | SR01    | f          |  10000
    (1 row)

Now, if we update the row (on the same day that we inserted it), the history
row is also updated:

.. code-block:: psql

    db=# update employees set salary = 20000.0 where emp_id = 1;
    UPDATE 1
    db=# select * from employees_history;
     effective  |   expiry   | emp_id |      name       |    dob     | dept_id | is_manager | salary
    ------------+------------+--------+-----------------+------------+---------+------------+--------
     2015-04-23 | 9999-12-31 |      1 | Fred Flintstone | 1960-07-05 | SR01    | f          |  20000
    (1 row)

Finally, if we delete the row (again, on the same day), the history row is
removed. In each case, the history table is showing the *final* state of the
row on the given day:

.. code-block:: psql

    db=# delete from employees where emp_id = 1;
    DELETE 1
    db=# select * from employees_history ;
     effective | expiry | emp_id | name | dob | dept_id | is_manager | salary
    -----------+--------+--------+------+-----+---------+------------+--------
    (0 rows)

However, if we insert the row again, then "cheat" and tweak the history table
so it appears as if it were inserted yesterday (we can do this because we are
the table owner but ordinary users would not have the necessary UPDATE
privilege), a subsequent UPDATE of the row will expire the old history row and
insert a new one:

.. code-block:: psql

    db=# insert into employees values (1, 'Fred Flintstone', '1960-07-05', 'SR01', false, 10000.0);
    INSERT 0 1
    db=# update employees_history set effective = effective - interval '1 day' where emp_id = 1;
    UPDATE 1
    db=# update employees set salary = 20000.0 where emp_id = 1;
    UPDATE 1
    db=# select * from employees_history;
     effective  |   expiry   | emp_id |      name       |    dob     | dept_id | is_manager | salary
    ------------+------------+--------+-----------------+------------+---------+------------+--------
     2015-04-22 | 2015-04-22 |      1 | Fred Flintstone | 1960-07-05 | SR01    | f          |  10000
     2015-04-23 | 9999-12-31 |      1 | Fred Flintstone | 1960-07-05 | SR01    | f          |  20000
    (2 rows)

Usually the first reaction of users of the history framework is "I'll just use
microsecond resolution because I want to keep all changes". I would caution
against this for several reasons:

* Firstly, there is no guarantee that all changes will be kept (although at the
  time of writing the author has never seen a setup that was capable of making
  two separate changes to the same record within the same microsecond, so this
  is a rather theoretical objection).
* Secondly, this implies that someone is attempting to use the extension as an
  auditing solution. For reasons discussed in the :ref:`history_design` section
  below, this is not a good idea.

If you are not attempting to build an auditing setup, consider carefully
whether you *really* need every single change. As an example, in one case the
author is aware of a company kept a record of every change to its employees
table. After a few years, the employees history table was over 6 million rows
long and caused significant performance problems in joins.

An analysis of the history table showed that over 90% of the rows had effective
ranges lasting less than a minute; the result of people making changes, then
correcting mistakes, or just making many changes as individual transactions.

For most data analysis or business intelligence purposes that the author has
been engaged in, day or sometimes even week resolution has proved sufficient
for all analytical purposes.

Finally, an offset can also be applied to all timestamp calculations undertaken
by the history triggers. This facility was primarily designed for dealing with
sources which significantly delay the delivery of their data, but for which a
history with accurate dates is still desired. See the API documentation for the
:func:`create_history_triggers` function for further information.

Limitations
-----------

It is worth noting that there are a few limitations on which tables can be used
as the basis for a history table:

* Base tables *must* have a primary key.
* The primary key of a base table must be immutable (you may have noticed that
  this will be enforced through the ``keychg`` trigger above).

It is still possible to update the primary key of a base table with a history
table but it must be done via a DELETE and INSERT operation rather than UPDATE
(this is how such an operation would be represented by the history in either
case, hence why this restriction is enforced).

.. _history_querying:

Querying
========

The structure of the history table can be understood as follows:

* For each row that currently exists in the base table, an equivalent row will
  exist in the history table with the expiry date set to 9999-12-31 (i.e. in
  the future because it is an extant row).
* For each row that historically existed in the base table, an equivalent row
  will exist in the history table with the effective and expiry dates
  indicating the range of dates between which that row existed in the base
  table.

Therefore, to query the state of the base table at date 2014-01-01 we can
simply use the following query:

.. code-block:: sql

    SELECT emp_id, name, dob, dept, is_manager, salary
    FROM employees_history
    WHERE '2014-01-01' BETWEEN effective AND expiry;

In general, to retrieve the state of a base table at a given timestamp from
a history table, one uses a query of this format:

.. code-block:: sql

    SELECT fields, of, the, base, table
    FROM history_table
    WHERE required_timestamp BETWEEN effective AND expiry;

If you have a join to the base table, you can join to the history table in the
same way: just include the criteria above to select the state of the table at
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
and a few other designs will be discussed in the :ref:`history_design` section
below.

While it is easy to query the state of the base table at a given timestamp, it
is harder to see how one could query changes within the history. For example,
which employees have received a salary increase? Usually for this, it is
necessary to self-join the history table so that one can see before and after
states for changes. Creation of such views is automated with the
:func:`create_history_changes` function. We can simply execute:

.. code-block:: psql

    db=# select create_history_changes('employees_history');
     create_history_changes
    ------------------------

    (1 row)

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
            ON (new.effective - interval '1 day'::interval) BETWEEN old.effective AND old.expiry
            AND old.emp_id = new.emp_id;

With this view it is now a simple matter to determine which employees have
received a salary increase:

.. code-block:: psql

    db=# select new_emp_id, new_name, old_salary, new_salary
    db-# from employees_changes where change = 'UPDATE' and new_salary > old_salary;
     new_emp_id |    new_name     | old_salary | new_salary
    ------------+-----------------+------------+------------
              1 | Fred Flintstone |      10000 |      20000
    (1 row)

Or we can find out who joined and who left during the last year:

.. code-block:: psql

    db=# select coalesce(old_emp_id, new_emp_id) as emp_id, coalesce(old_name, new_name) as name
    db-# from employees_changes where change in ('INSERT', 'DELETE') and changed >= current_date - interval '1 year';
     emp_id |      name
    --------+-----------------
          1 | Fred Flintstone
    (1 row)

Another common use case of history tables is to see the changes in data over
time via regular snapshots. This is also easily accomplished with the
:func:`create_history_snapshots` function which takes the history table and
a resolution (which must be greater than the history table's resolution).
For example, to view the employees table as a series of monthly snapshots:

.. code-block:: psql

    db=# select create_history_snapshots('employees_history', 'month');
     create_history_snapshots
    --------------------------

    (1 row)

This is equivalent to executing the following SQL:

.. code-block:: sql

    CREATE VIEW employees_by_month AS
    WITH RECURSIVE range(at) AS (
        SELECT min(employees_history.effective) AS min
        FROM employees_history

        UNION ALL

        SELECT range.at + interval '1 month'
        FROM range
        WHERE range.at + interval '1 month' <= current_date
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
            ON r.at BETWEEN h.effective AND h.expiry;

The resulting view has the same structure as the base table, but with one extra
column at the start: ``snapshot`` which in the case above will contain a date
running from the lowest date in the history to the current date in monthly
increments. If we wished for an employee head-count by month we could simply
use the following query:

.. code-block:: psql

    db=# select snapshot, count(*) as head_count
    db-# from employees_by_month
    db-# group by snapshot;
          snapshot       | head_count
    ---------------------+------------
     2015-04-30 00:00:00 |          1
    (1 row)

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

.. _history_maintenance:

Maintenance
===========

For the most part, the history table should maintain itself. The same goes for
any changes or snapshots views which you create (the latter automatically uses
the minimum effective date in the underlying history table, and today's current
date as its range).

However, there are circumstances under which it is necessary to perform
manual maintenance of the history structures which are detailed in the sections
below.

Structural Changes
------------------

You may find yourself needing to change the structure of the base table feeding
the history table. Naturally, this is more complicated than simply altering a
regular table. The first thing to determine is whether the modification you
wish to make is capable of being made in a way that does not damage the
history.

For example, if you are adding a column, the history table may also need that
column added in which case you will either need to make the column nullable
or come up with some suitable default (similar to adding a column to any
non-empty table). The procedure is as follows:

1. Destroy the existing history triggers
2. Alter the base table
3. Alter the history table
4. Re-creating the history triggers

Thankfully, PostgreSQL supports transactional DDL which means we can accomplish
all this in a single transaction with inconsistent states invisible to other
active transactions, as demonstrated below:

.. code-block:: psql

    db=# begin;
    BEGIN
    db=# select drop_history_triggers('employees');
     drop_history_triggers
    -----------------------

    (1 row)

    db=# alter table employees add column full_time boolean default true not null;
    ALTER TABLE
    db=# alter table employees_history add column full_time boolean default true not null;
    ALTER TABLE
    db=# select create_history_triggers('employees', 'day');
     create_history_triggers
    -------------------------

    (1 row)

    db=# commit;
    COMMIT

Note that the history table need not have all the attributes of the base table.
This is specifically to support the use-case where certain attributes of the
base table should not be tracked (in this case one can create the history table
with :func:`create_history_table`, drop certain attributes from the newly
created table with :ref:`ALTER TABLE` and then create the triggers). However,
all primary key columns from the base table must exist in the history table.

Removing a column is a similar process, provided it's not a key column.
Remember that history triggers *require* a primary key on the base table and
that the history tables also require that key plus the effective column.
Therefore, unless you are sure that removing a key column leaves a unique key
sufficient to identify each row in the base *and* history tables (when combined
with the effective date), you cannot remove it.

Altering columns is also a similar process: just remember to alter the history
table in the same way as the base table in between destroying and recreating
the triggers.

Archiving
---------

In the case that you wish to make an alteration to the base table that cannot
also be made in the history table, you may wish to store the current history
table as an archive, then create a new one starting from the current point
in time. The procedure is as follows:

1. Destroy the history triggers
2. Alter the base table
3. Expire all rows in the history table (this requires calculating the prior
   date or timestamp for the selected resolution)
4. Rename the history table
5. Create a new history table (remember that this will copy data from the
   base table)
6. Recreate the history triggers

For example, consider the case where we want to store employee's salary in
local currency instead of US dollars. Firstly this will entail adding a field
to store the currency, and then updating all the salaries accordingly. Let us
assume that we do not have a historical record of currency exchange rates and
thus the decision is made to leave the current history as US dollars and start
a new history.

.. code-block:: psql

    db=# begin;
    BEGIN
    db=# select drop_history_triggers('employees');
     drop_history_triggers
    -----------------------

    (1 row)

    db=# create table currencies (cur_id char(3) not null primary key, usd_to_lcl decimal(12, 4) not null);
    CREATE TABLE
    db=# insert into currencies values ('USD', 1.0), ('GBP', 0.66), ('EUR', 0.92), ('CNY', 6.20), ('JPY', 119.47);
    INSERT 0 5
    db=# alter table employees add cur_id char(3) default 'EUR' not null references currencies (cur_id);
    ALTER TABLE
    db=# update employees e set salary = salary * usd_to_lcl from currencies c where e.cur_id = c.cur_id;
    UPDATE 1
    db=# update employees_history set expiry = current_date - interval '1 day' where expiry = '9999-12-31';
    UPDATE 0
    db=# alter table employees_history rename to employees_history_old;
    ALTER TABLE
    db=# alter index employees_history_pkey rename to employees_history_old_pkey;
    ALTER INDEX
    db=# alter index employees_history_ix1 rename to employees_history_old_ix1;
    ALTER INDEX
    db=# alter index employees_history_ix2 rename to employees_history_old_ix2;
    ALTER INDEX
    db=# select create_history_table('employees', 'day');
     create_history_table
    ----------------------

    (1 row)

    db=# select create_history_triggers('employees', 'day');
     create_history_triggers
    -------------------------

    (1 row)

    db=# commit;
    COMMIT

Obviously this requires users querying the history to bridge the discontinuity
themselves (for example, by unioning compatible transforms or subsets of the
two histories). You may wish to provide a convenience view in such cases.

The same process can be used in the case you simply wish to archive the
existing history for performance reasons. Obviously in this case you would
not alter the base table, but it would still be necessary to disable and
re-create the history triggers.

Finally, in certain rare circumstances you may find that you need to alter the
content of the history without affecting the base table. In this case you can
simply disable the existing triggers, make your alterations and re-enable them.
However, you must be extremely careful to ensure that you do not create
overlapping history ranges, or contradict the current state of the base table
(by affecting rows with expiry date 9999-12-31).

For example, to double all the historical salaries (without affecting current
ones):

.. code-block:: psql

    db=# begin;
    BEGIN
    db=# alter table employees disable trigger all;
    ALTER TABLE
    db=# update employees_history set salary = salary * 2.0 where expiry < '9999-12-31';
    UPDATE 0
    db=# alter table employees enable trigger all;
    ALTER TABLE
    db=# commit;
    COMMIT

.. _history_design:

Design
======

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
  minimal compared to other designs, although not perfectly minimal (see
  next section).

* Performance and space: this system provides a wide variety of resolutions for
  the history table and triggers. In the case that every single update does not
  need to be kept (and generally this is not a requirement for many reporting
  databases) this permits one to keep a minimal history to maintain
  performance.

The above qualities make this extension useful for data science and business
intelligence purposes, especially where data gathering is a long term exercise.
It can also be used for general purpose temporal data storage, although it does
not provide all the facilities provided by the aforementioned implementations
bundled with the major commercial engines.

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

This particular extension is unsuitable for creating audit mechanisms. Firstly
it does not keep track of which user made which inserts or updates. Secondly,
even if such functionality were added to the base table there would be no way
of representing who performed a deletion (as there's no row in the history
table representing deletions; they are represented by a shortened effective
range). Thirdly, and crucially for an audit system, it provides no means of
storing details of operations that *failed*.

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

.. function:: drop_history_triggers(source_schema, source_table)
              drop_history_triggers(source_table)

    :param source_schema: The schema containing the base table. Defaults to
        the current schema if omitted.
    :param source_table: The table to use as a basis for the history table.

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

