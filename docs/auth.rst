.. module:: auth

======================
The ``auth`` Extension
======================

The auth extension was originally created to manage bulk authorization
transfers in large scale data warehouses. It can be installed and removed in
the standard manner:

.. code-block:: sql

    CREATE EXTENSION auth;
    DROP EXTENSION auth;

It is a relocatable, pure SQL extension which therefore requires no external
libraries or compilation, and consists mostly of user-callable functions, with
one table for storage.

Usage
=====

Ideally large data warehouses would have a relatively small set of well defined
roles which would be assigned to user IDs, granting them access to exactly what
they need. Unfortunately, reality is rarely so well ordered. Data warehouses
have a nasty habit of growing over time, and sometimes developers or admins
will cut corners and grant authorities on objects directly to users instead of
going via roles.

This leads to all sorts of issues when people inevitably move around, join and
leave organizations, or simply go on holiday and need to grant another person
access to the same objects while they're away. While one solution to such
issues is simply to share the password for the user, this is hardly ideal from
a security perspective.

The ``auth`` extension provides a partial solution to such issues with the
:func:`copy_role_auths` function which, given a source and a target username
will grant authorities to the target which the source has, but the target
currently does not.

.. note::

    Note that the current implementation only covers tables (and table-like
    objects such as views), functions, and roles. Authorizations for other
    objects are *not* copied.

For example:

.. code-block:: sql

    SELECT copy_role_auths('fred', 'barney');

Another function, :func:`remove_role_auths` is provided to remove all
authorities from a user, and this is also used in the implementation of
:func:`move_role_auths` which simply performs a copy of authorities, then
removes them from the source user:

.. code-block:: sql

    SELECT move_role_auths('fred', 'barney');
    SELECT remove_role_auths('wilma');

.. note::

    Removing authorities from a user does *not* remove the authorities they
    derive from being the owner of an object. To remove these as well, see
    :ref:`REASSIGN OWNED`.

The other set of functions provided by the ``auth`` extension have to do with
the manipulation of table authorities. The :func:`store_table_auths` function
stores all authorizations for a table in the ``stored_table_auths`` table
(constructed by the extension). The :func:`restore_table_auths` function can
then be used to restore the authorizations to the table (removing them from
``stored_table_auths`` in the process).

These routines can be used in a number of scenarios. The simplest is when a
table needs to be reconstructed (to deal with some structural change that
cannot be accomplished with :ref:`ALTER TABLE`) and you wish to maintain the
authorizations for the table:

.. code-block:: sql

    SELECT store_table_auths('foo');
    DROP TABLE foo;
    CREATE TABLE foo (i integer NOT NULL, j integer NOT NULL);
    -- Reload data into foo (e.g. from an export)
    SELECT restore_table_auths('foo');

However, given that the ``stored_table_auths`` table can itself be manipulated,
it can also be used for other effects. For example, to copy the authorizations
from one table to another:

.. code-block:: sql

    SELECT store_table_auths('foo');
    CREATE TABLE bar (i integer NOT NULL);
    UPDATE stored_table_auths SET table_name = 'bar' WHERE table_name = 'foo';
    SELECT restore_table_auths('bar');

Or, to ensure that anyone who can ``SELECT`` from table ``foo``, can also
``SELECT`` from the view ``bar`` (ignoring other privileges like ``INSERT``,
``UPDATE``, and such like):

.. code-block:: sql

    SELECT store_table_auths('foo');
    CREATE VIEW bar AS SELECT * FROM foo;
    DELETE FROM stored_table_auths
        WHERE table_name = 'foo'
        AND privilege_type <> 'SELECT';
    UPDATE stored_table_auths SET table_name = 'bar'
        WHERE table_name = 'foo';
    SELECT restore_table_auths('bar');

See :func:`~history.create_history_table` for an example of this usage.

API
===

.. function:: role_auths(auth_name)

    :param auth_name: The role to retrieve authorizations for

    This is a table function which returns one row for each privilege held
    by the specified authorization name. The rows have the following structure:

    +-------------+--------------+-------------------------------------------+
    | Column      | Type         | Description                               |
    +=============+==============+===========================================+
    | object_type | varchar(20)  | 'TABLE', 'FUNCTION', or 'ROLE'            |
    +-------------+--------------+-------------------------------------------+
    | object_id   | oid          | The oid of the table or function, NULL if |
    |             |              | object_type is 'ROLE'                     |
    +-------------+--------------+-------------------------------------------+
    | auth        | varchar(140) | The name of the authorization, e.g.       |
    |             |              | 'SELECT', 'EXECUTE', 'REFERENCES', or     |
    |             |              | the name of the role if object_type is    |
    |             |              | 'ROLE'                                    |
    +-------------+--------------+-------------------------------------------+
    | suffix      | varchar(20)  | The string 'WITH GRANT OPTION' or         |
    |             |              | 'WITH ADMIN OPTION' if the authority was  |
    |             |              | granted with these options. A blank       |
    |             |              | string otherwise.                         |
    +-------------+--------------+-------------------------------------------+

    At present, the function is limited to authorities derived from tables
    (and table-like structures), functions, and roles.

.. function:: auth_diff(source, dest)

    :param source: The base role to compare authorizations against
    :param dest: The target role to test for similar authorities

    This table function is effectively a set subtraction function. It takes the
    set of authorities from the *source* role and subtracts from them the set
    of authorities that apply to the *target* role (both derived by calling
    :func:`role_auths`). The result is returned as a table with the same
    structure as that returned by :func:`role_auths`.

    Note that if *source* holds SELECT WITH GRANT OPTION on a table, while
    *target* holds SELECT (with no GRANT option), then this function will
    consider those different "levels" of the grant and the result will include
    SELECT WITH GRANT OPTION.

.. function:: copy_role_auths(source, dest)

    :param source: The role to copy authorities from
    :param dest: The role to copy authorities to

    This function determines the :ref:`GRANTs <GRANT>` that need to be execute
    in order for *dest* to have the same rights to all objects as *source*
    (this is done with the :func:`auth_diff` function documented above). It
    then attempts to execute all such GRANTs; the calling user must have the
    authority to do this, therefore the use of this function is typically
    restricted to super users.

.. function:: remove_role_auths(auth_name)

    :param auth_name: The role to remove authorities from

    This function attempts to :ref:`REVOKE` all authorities from the specified
    role *auth_name*. This is not a great deal of use on PostgreSQL where it is
    simpler to just delete the role, but it is used by :func:`move_role_auths`
    below.

    .. warning::

        This will not remove authorities derived from ownership of an object.

.. function:: move_role_auths(source, dest)

    :param source: The role to remove authorities from
    :param dest: The role to transfer authorities to

    This function attempts to transfer all authorities from the *source* role
    to the *dest* role with a combination of :func:`copy_role_auths` and
    :func:`remove_role_auths`.

    As in the case of :func:`copy_role_auths`, the calling user must have the
    authority to execute all necessary :ref:`GRANTs <GRANT>` and :ref:`REVOKEs
    <REVOKE>`, therefore the use of this function is typically restricted to
    super users.

    .. warning::

        This will not remove authorities derived from ownership of objects
        from *source*. See :ref:`REASSIGN OWNED` for a method of accomplishing
        this.

.. function:: store_table_auths(aschema, atable)
              store_table_auths(atable)

    :param aschema: The schema containing the table to read authorizations for
    :param atable: The table to read authorizations for

    This function writes all authorities that apply to the table *atable*
    (in schema *aschema* or the current schema if this is omitted) to the
    ``stored_table_auths`` table which has the following structure:

    +----------------+---------+--------------------------------------+
    | Column         | Type    | Description                          |
    +================+=========+======================================+
    | table_schema   | name    | The schema of the table              |
    +----------------+---------+--------------------------------------+
    | table_name     | name    | The name of the table the privilege  |
    |                |         | applies to                           |
    +----------------+---------+--------------------------------------+
    | grantee        | name    | The role the privilege is granted to |
    +----------------+---------+--------------------------------------+
    | privilege_type | varchar | The name of the privilege, e.g.      |
    |                |         | SELECT, UPDATE, etc.                 |
    +----------------+---------+--------------------------------------+
    | is_grantable   | boolean | If the privilege was granted WITH    |
    |                |         | GRANT OPTION, then this is true      |
    +----------------+---------+--------------------------------------+

    The table is keyed by table_schema, table_name, grantee, and
    privilege_type.

    No errors will be raised if rows already exist in ``stored_table_auths``
    violating this key; they will be updated instead.  In other words, it is
    not an error to run this procedure multiple times in a row for the same
    table. However, the similar :func:`restore_table_auths` removes rows from
    this table, therefore usual practice is to perform the two functions within
    the same transaction effectively leaving the ``stored_table_auths`` table
    unchanged after.

.. function:: restore_table_auths(aschema, table)
              restore_table_auths(atable)

    :param aschema: The schema containing the table to write authorizations to
    :param atable: The table to write authorizations to

    This function removes rows from the ``stored_table_auths`` table
    (documented above for :func:`store_table_auths` function) and attempts to
    execute the :ref:`GRANT` represented by each row. Updating the
    ``stored_table_auths`` table between calls to :func:`store_table_auths` and
    this function permits various effects, including copying authorizations
    from one table to another, manipulating the list of authorities to be
    copied, and so on.

