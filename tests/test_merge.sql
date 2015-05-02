CREATE TABLE foo (
    id integer NOT NULL,
    value integer NOT NULL
);

CREATE TABLE bar AS (SELECT * FROM foo) WITH NO DATA;
ALTER TABLE bar ADD CONSTRAINT bar_pk PRIMARY KEY (id);

INSERT INTO foo VALUES
    (1, 2),
    (2, 4),
    (3, 8),
    (4, 16),
    (5, 32);

SELECT auto_merge('foo', 'bar', 'bar_pk');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT * FROM foo
        INTERSECT
        SELECT * FROM bar
    ) AS t), 5::bigint));

INSERT INTO foo VALUES
    (6, 64),
    (7, 128);

SELECT auto_merge('foo', 'bar', 'bar_pk');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT * FROM foo
        INTERSECT
        SELECT * FROM bar
    ) AS t), 7::bigint));

DELETE FROM foo WHERE id IN (1, 2);

SELECT auto_delete('foo', 'bar');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT * FROM foo
        INTERSECT
        SELECT * FROM bar
    ) AS t), 5::bigint));

DELETE FROM foo;
SELECT auto_delete('foo', 'bar');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT * FROM foo
        INTERSECT
        SELECT * FROM bar
    ) AS t), 0::bigint));

CREATE TABLE baz (
    country char(2) NOT NULL,
    id integer NOT NULL,
    givenname varchar(100) NOT NULL,
    surname varchar(100) not null,
    age integer default 0 not null
);

CREATE TABLE emp (
    country char(2) NOT NULL,
    id integer NOT NULL,
    givenname varchar(100) NOT NULL,
    surname varchar(100) not null,
    CONSTRAINT emp_pk PRIMARY KEY (country, id)
);

INSERT INTO baz VALUES
    ('GB', 1, 'Fred', 'Flintstone', 35),
    ('GB', 2, 'Barney', 'Rubble', 32),
    ('GB', 3, 'Wilma', 'Flintstone', 33),
    ('GB', 4, 'Betty', 'Rubble', 32);

SELECT auto_insert('baz', 'emp');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT country, id, givenname, surname FROM baz
        INTERSECT
        SELECT country, id, givenname, surname FROM emp
    ) AS t), 4::bigint));

INSERT INTO baz VALUES
    ('GB', 5, 'Pebbles', 'Flintstone', 2),
    ('GB', 6, 'Bamm-Bamm', 'Rubble', 3);

SELECT auto_merge('baz', 'emp');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT country, id, givenname, surname FROM baz
        INTERSECT
        SELECT country, id, givenname, surname FROM emp
    ) AS t), 6::bigint));

DROP TABLE foo;
DROP TABLE bar;
DROP TABLE baz;
DROP TABLE emp;

CREATE TABLE foo (
    id1 integer not null,
    id2 integer not null,
    primary key (id1, id2)
);

INSERT INTO foo VALUES (1, 1), (2, 2), (3, 3);
CREATE TABLE bar AS (SELECT * FROM foo) WITH NO DATA;
ALTER TABLE bar ADD CONSTRAINT bar_pk PRIMARY KEY (id1, id2);
INSERT INTO bar VALUES (1, 1);

SELECT auto_merge('foo', 'bar');
VALUES (assert_equals((
    SELECT count(*)
    FROM (
        SELECT * FROM foo
        INTERSECT
        SELECT * FROM bar
    ) AS t), 3::bigint));

DROP TABLE foo;
DROP TABLE bar;

-- vim: set et sw=4 sts=4:
