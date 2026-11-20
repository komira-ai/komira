-- The join-shape corpus's tables: integer keys with orphans, duplicates and a
-- NULL on each side (L, R), a shared key name (K, M), an empty table (E),
-- DOUBLE keys with NaN and -0.0 against 0.0 (F, G), string keys (S, S2, D,
-- D2) and a two-column key (MK, MK2). A DOUBLE is written as a quoted
-- literal cast to DOUBLE: an unquoted -0.0 parses as a DECIMAL and loses
-- its sign.
CREATE TABLE L (lk BIGINT, lv BIGINT, ls VARCHAR);
INSERT INTO L VALUES
    (1, 10, 'a'),
    (2, 20, 'b'),
    (2, 21, 'bb'),
    (3, 30, 'c'),
    (4, 40, 'd'),
    (NULL, 50, 'e');
CREATE TABLE R (rk BIGINT, rv BIGINT, rs VARCHAR);
INSERT INTO R VALUES
    (2, 200, 'x'),
    (2, 201, 'xx'),
    (3, 300, 'y'),
    (5, 500, 'z'),
    (NULL, 600, 'w');
CREATE TABLE K (k BIGINT, a BIGINT);
INSERT INTO K VALUES
    (1, 11),
    (2, 22),
    (3, 33);
CREATE TABLE M (k BIGINT, b BIGINT);
INSERT INTO M VALUES
    (2, 220),
    (3, 330),
    (4, 440);
CREATE TABLE E (rk BIGINT, rv BIGINT, rs VARCHAR);
CREATE TABLE F (fk DOUBLE, fv BIGINT);
INSERT INTO F VALUES
    ('1.0'::DOUBLE, 1),
    ('nan'::DOUBLE, 2),
    ('2.5'::DOUBLE, 3),
    (NULL, 4),
    ('-0.0'::DOUBLE, 5);
CREATE TABLE G (gk DOUBLE, gv BIGINT);
INSERT INTO G VALUES
    ('1.0'::DOUBLE, 10),
    ('nan'::DOUBLE, 20),
    ('2.5'::DOUBLE, 30),
    ('0.0'::DOUBLE, 40);
CREATE TABLE S (sk VARCHAR, sv BIGINT);
INSERT INTO S VALUES
    ('a', 1),
    ('b', 2),
    ('b', 3),
    (NULL, 4);
CREATE TABLE S2 (tk VARCHAR, tv BIGINT);
INSERT INTO S2 VALUES
    ('a', 100),
    ('b', 200),
    ('c', 300);
CREATE TABLE D (dk VARCHAR, dv BIGINT);
INSERT INTO D VALUES
    ('a', 10),
    ('b', 20),
    ('c', 30);
CREATE TABLE D2 (ek VARCHAR, ev BIGINT);
INSERT INTO D2 VALUES
    ('b', 2),
    ('a', 1),
    ('d', 4);
CREATE TABLE MK (m1 BIGINT, m2 VARCHAR, mv BIGINT);
INSERT INTO MK VALUES
    (1, 'p', 1),
    (2, 'p', 2),
    (2, 'q', 3),
    (3, 'p', 4);
CREATE TABLE MK2 (n1 BIGINT, n2 VARCHAR, nv BIGINT);
INSERT INTO MK2 VALUES
    (1, 'p', 10),
    (2, 'p', 20),
    (3, 'z', 30);
