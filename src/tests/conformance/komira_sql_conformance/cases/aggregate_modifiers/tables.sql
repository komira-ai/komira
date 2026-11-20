-- Tables for DISTINCT aggregates, GROUP BY shapes and HAVING. T has a string key
-- g with a NULL group, an int key g2, a nullable int v with repeats, a DOUBLE f
-- holding 0.0 and -0.0 (quoted so the sign survives), and a column n that is
-- NULL on every row.
CREATE TABLE T (k BIGINT, g VARCHAR, g2 BIGINT, v BIGINT, f DOUBLE, n BIGINT);
INSERT INTO T VALUES
    (1, 'a', 10, 1, '1.1'::DOUBLE, NULL),
    (2, 'a', 10, 1, '1.9'::DOUBLE, NULL),
    (3, 'a', 20, 2, '-0.0'::DOUBLE, NULL),
    (4, 'b', 10, NULL, '0.0'::DOUBLE, NULL),
    (5, 'b', 20, 3, '2.5'::DOUBLE, NULL),
    (6, NULL, 10, 3, '2.5'::DOUBLE, NULL),
    (7, NULL, 20, NULL, NULL, NULL),
    (8, 'c', 10, 1, '0.0'::DOUBLE, NULL),
    (9, 'c', 10, 1, '-0.0'::DOUBLE, NULL);
