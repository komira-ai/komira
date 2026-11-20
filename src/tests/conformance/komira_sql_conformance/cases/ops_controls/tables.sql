-- Small tables for operator controls. T has six rows in three groups of two, a genuine
-- empty string beside a NULL string in a different row, a NULL integer in another row,
-- and the same word in two letter cases. U has a key T lacks, so an inner and a left join
-- differ. C shares column names with U. B is a BOOLEAN column kept off T.
CREATE TABLE T (k BIGINT, g BIGINT, v DOUBLE, s VARCHAR, n BIGINT);
INSERT INTO T VALUES
    (0, 0, 10.0, '', 1),
    (1, 0, 20.0, 'ab', 2),
    (2, 1, 30.0, 'AB', CAST(NULL AS BIGINT)),
    (3, 1, 40.0, CAST(NULL AS VARCHAR), 4),
    (4, 2, 50.0, 'zz', 5),
    (5, 2, 60.0, 'ab', 6);
CREATE TABLE U (j BIGINT, w BIGINT);
INSERT INTO U VALUES
    (1, 100),
    (2, 200),
    (3, 300),
    (9, 900);
CREATE TABLE C (k BIGINT, w BIGINT, w_right BIGINT);
INSERT INTO C VALUES
    (1, 11, 111),
    (2, 22, 222),
    (3, 33, 333);
CREATE TABLE B (bk BIGINT, b BOOLEAN);
INSERT INTO B VALUES
    (0, true),
    (1, false),
    (2, true);
