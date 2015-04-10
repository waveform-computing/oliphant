.. module:: auth

======================
The ``auth`` Extension
======================

The auth extension was originally created to manage bulk authorization
transfers in large scale data warehouses. It can be installed and removed in
the standard manner::

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

For example::

    SELECT copy_role_auths('fred', 'barney');

Another function, :func:`remove_role_auths` is provided to remove all
authorities from a user, and this is also used in the implementation of
:func:`move_role_auths` which simply performs a copy of authorities, then
removes them from the source user::

    SELECT move_role_auths('fred', 'barney');
    SELECT remove_role_auths('wilma');

.. note::

    Removing authorities from a user does *not* remove the authorities they
    derive from being the owner of an object. To remove these as well, see
    :ref:`REASSIGN OWNED`.


