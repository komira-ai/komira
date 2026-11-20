-- Tables named t_full, t_single, t_nulls, t_allnull and t_empty (only those a case uses),
-- each with k (row number), g (k modulo 2) and v of type UTINYINT. t_full holds six values
-- at the type's edges; t_single keeps the first; t_nulls blanks rows 1 and 4; t_allnull
-- is all NULL; t_empty has no rows.
CREATE TABLE t_full (k BIGINT, g BIGINT, v UTINYINT);
INSERT INTO t_full VALUES
    (0, 0, 0),
    (1, 1, 1),
    (2, 0, 2),
    (3, 1, 128),
    (4, 0, 254),
    (5, 1, 255);
