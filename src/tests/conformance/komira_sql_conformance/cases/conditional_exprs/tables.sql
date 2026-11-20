-- Tables for CASE, COALESCE, NULLIF, IFNULL, GREATEST and LEAST cases. T holds
-- eight rows: an all-NULL row, one-sided NULLs in the int and string columns,
-- negative and zero ints, an empty string, mixed-case strings, and a DOUBLE
-- column (quoted literals cast to DOUBLE so no value turns into a DECIMAL).
CREATE TABLE T (k BIGINT, a BIGINT, b BIGINT, f DOUBLE, s VARCHAR, u VARCHAR);
INSERT INTO T VALUES
    (0, NULL, NULL, NULL, NULL, NULL),
    (1, 1, 1, '1.0'::DOUBLE, 'a', 'a'),
    (2, 2, 3, '2.5'::DOUBLE, 'b', 'c'),
    (3, NULL, 5, '-1.5'::DOUBLE, NULL, 'z'),
    (4, 7, NULL, '0.0'::DOUBLE, 'q', NULL),
    (5, -3, -3, '3.25'::DOUBLE, '', 'abc'),
    (6, 0, 0, NULL, 'A', 'a'),
    (7, 10, 2, '100.0'::DOUBLE, 'zz', 'b');
