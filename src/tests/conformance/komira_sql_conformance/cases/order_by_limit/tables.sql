-- Twelve rows for ORDER BY, LIMIT and OFFSET.
-- a: BIGINT with ties and two NULLs; b: BIGINT; d: DOUBLE with NaN, inf, -inf, ties and NULLs;
-- s: text with NULL, the empty string, mixed case, a leading space and non-ASCII;
-- c: low-cardinality text; g: a BIGINT group with no NULLs that splits rows differently from c.
CREATE TABLE T (k BIGINT, a BIGINT, b BIGINT, d DOUBLE, s VARCHAR, c VARCHAR, g BIGINT);
INSERT INTO T VALUES
    (0, 3, 1, '1.5'::DOUBLE, 'apple', 'red', 2),
    (1, 1, 2, NULL, 'Banana', 'blue', 1),
    (2, NULL, 1, 'nan'::DOUBLE, NULL, 'red', 2),
    (3, 3, 0, 'inf'::DOUBLE, '', 'green', 3),
    (4, 2, 5, '-inf'::DOUBLE, 'Apple', 'blue', 1),
    (5, 1, 1, '0.0'::DOUBLE, 'apple pie', 'red', 2),
    (6, NULL, 9, '7.25'::DOUBLE, 'Ünïcodé', 'green', 3),
    (7, 10, 3, '-3.75'::DOUBLE, 'banana', 'blue', 1),
    (8, 3, 7, '2.5'::DOUBLE, 'a', 'blue', 2),
    (9, -5, 4, NULL, 'Z', 'green', 3),
    (10, 0, 8, '0.0'::DOUBLE, 'zebra', 'blue', 1),
    (11, 2, 2, 'nan'::DOUBLE, ' lead', 'red', 2);
