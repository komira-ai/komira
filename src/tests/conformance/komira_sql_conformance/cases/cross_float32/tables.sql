-- Tables named t_full, t_single, t_nulls, t_allnull and t_empty (only those a case uses),
-- each with k (row number), g (k modulo 2) and v of type FLOAT. t_full holds six values
-- at the type's edges; t_single keeps the first; t_nulls blanks rows 1 and 4; t_allnull
-- is all NULL; t_empty has no rows.
CREATE TABLE t_full (k BIGINT, g BIGINT, v FLOAT);
INSERT INTO t_full VALUES
    (0, 0, '1.5'::FLOAT),
    (1, 1, '2.5'::FLOAT),
    (2, 0, '3.5'::FLOAT),
    (3, 1, '4.5'::FLOAT),
    (4, 0, '5.5'::FLOAT),
    (5, 1, '6.5'::FLOAT);
