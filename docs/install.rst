.. _server_install:

===================
Server installation
===================

The following sections detail adding the Oliphant extensions to your PostgreSQL
server installation. Please select an installation method which meets your
needs.


.. _install_ubuntu:

Ubuntu installation
===================

The following assumes you already have a PostgreSQL server installed on your
Ubuntu machine. To install the pre-requisites, clone the Oliphant repository
and install the extensions within your PostgreSQL server:

.. code-block:: console

    $ sudo apt-get install git make postgresql-server-dev-all
    $ git clone https://github.com/waveform80/oliphant.git
    $ cd oliphant
    $ sudo make install


.. _install_windows:

Microsoft Windows installation
==============================

Pull requests for instructions gratefully received.


.. _install_mac_os:

Mac OS X installation
=====================

Pull requests for instructions gratefully received.


.. _install_development:

Development installation
========================

If you wish to develop oliphant itself, it is easiest to use the ``develop``
target of the makefile. This does something similar to ``install``, but creates
symlinks within your PostgreSQL extension directory which makes it a bit easier
to hack on the code. The following assumes Ubuntu:

.. code-block:: console

    $ sudo apt-get install git make postgresql-server-dev-all
    $ git clone https://github.com/waveform80/oliphant.git
    $ cd oliphant
    $ sudo make develop


.. _database_install:

=====================
Database installation
=====================

Once the Oliphant extensions have been added to your PostgreSQL installation
you can install them in the database(s) of your choice. To do this manually
simply use the `CREATE EXTENSION`_ with the extensions, e.g.:

.. code-block:: psql

    db=# CREATE EXTENSION auth;
    CREATE EXTENSION
    db=# CREATE EXTENSION history;
    CREATE EXTENSION

Alternatively, you can use the ``installdb`` target of the makefile. This will
install all extensions available in Oliphant into the target database. This
defaults to the same database as your username but you can edit the makefile
to change this:

.. code-block:: console

    $ make installdb
    for m in assert auth history merge; do \
                    psql -d db -c "CREATE EXTENSION $m"; \
            done
    CREATE EXTENSION
    CREATE EXTENSION
    CREATE EXTENSION
    CREATE EXTENSION

.. _CREATE EXTENSION: http://www.postgresql.org/docs/9.1/static/sql-createextension.html


.. _test_suite:

====================
Test suite execution
====================

With the extensions installed in a database (see :ref:`database_install`
above), simply make the ``test`` target. All tests are echoed to stdout and any
test that fails causes the script to immediately stop allowing the developer to
diagnose the failure.

