-- Subquery and CTE fixture: T(k, g, v, s, n) with a NULL and an empty string in s, a NULL in n
-- and repeated groups in g; U(j, w) with keys that mostly match T.k plus one orphan (9).
CREATE TABLE T (k BIGINT, g BIGINT, v DOUBLE, s VARCHAR, n BIGINT);
INSERT INTO T VALUES
    (0, 0, '10.0'::DOUBLE, '', 1),
    (1, 0, '20.0'::DOUBLE, 'ab', 2),
    (2, 1, '30.0'::DOUBLE, 'AB', NULL),
    (3, 1, '40.0'::DOUBLE, NULL, 4),
    (4, 2, '50.0'::DOUBLE, 'zz', 5),
    (5, 2, '60.0'::DOUBLE, 'ab', 6);
CREATE TABLE U (j BIGINT, w BIGINT);
INSERT INTO U VALUES
    (1, 100),
    (2, 200),
    (3, 300),
    (9, 900);
