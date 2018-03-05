.. -*- rst -*-

========
oliphant
========

This package provides a set of extensions for PostgreSQL 9.x (or above). The
following extensions are currently included:

* *assert* - A set of routines for asserting the truth of various things
  (equality or inequality of values, existence of tables and columns, etc.);
  useful for building test suites.

* *auth* - A set of routines for bulk manipulation of authorizations including
  copying all authorizations from one user to another, and transferring all
  authorizations from one table to another.

* *history* - A set of routines for simplifying the creation of temporal
  tables; tables that track the state of another table via a series of triggers
  on the base table.

* *merge* - Routines for bulk transfer of data between similarly structured
  tables or views.

Links
=====

* The code is licensed under the `MIT license`_
* The `source code`_ can be obtained from GitHub, which also hosts the `bug
  tracker`_
* The `documentation`_ (which includes installation and usage examples) can
  be read on ReadTheDocs

.. _MIT license: http://opensource.org/licenses/MIT
.. _source code: https://github.com/waveform-computing/oliphant
.. _bug tracker: https://github.com/waveform-computing/oliphant/issues
.. _documentation: http://oliphant.readthedocs.org/

