-- Tables named t_full, t_single, t_nulls, t_allnull and t_empty (only those a case uses),
-- each with k (row number), g (k modulo 2) and v of type TIMESTAMPTZ. t_full holds six values
-- at the type's edges; t_single keeps the first; t_nulls blanks rows 1 and 4; t_allnull
-- is all NULL; t_empty has no rows.
CREATE TABLE t_full (k BIGINT, g BIGINT, v TIMESTAMPTZ);
INSERT INTO t_full VALUES
    (0, 0, TIMESTAMPTZ '2024-01-01 01:30:15.123456+00'),
    (1, 1, TIMESTAMPTZ '2024-01-01 02:30:15.123456+00'),
    (2, 0, TIMESTAMPTZ '2024-01-01 03:30:15.123456+00'),
    (3, 1, TIMESTAMPTZ '2024-01-01 04:30:15.123456+00'),
    (4, 0, TIMESTAMPTZ '2024-01-01 05:30:15.123456+00'),
    (5, 1, TIMESTAMPTZ '2024-01-01 06:30:15.123456+00');
