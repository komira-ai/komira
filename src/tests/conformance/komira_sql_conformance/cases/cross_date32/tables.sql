-- Tables named t_full, t_single, t_nulls, t_allnull and t_empty (only those a case uses),
-- each with k (row number), g (k modulo 2) and v of type DATE. t_full holds six values
-- at the type's edges; t_single keeps the first; t_nulls blanks rows 1 and 4; t_allnull
-- is all NULL; t_empty has no rows.
CREATE TABLE t_full (k BIGINT, g BIGINT, v DATE);
INSERT INTO t_full VALUES
    (0, 0, DATE '2024-01-01'),
    (1, 1, DATE '2024-01-02'),
    (2, 0, DATE '2024-01-03'),
    (3, 1, DATE '2024-01-04'),
    (4, 0, DATE '2024-01-05'),
    (5, 1, DATE '2024-01-06');
