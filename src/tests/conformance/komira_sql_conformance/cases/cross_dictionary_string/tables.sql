-- Tables named t_full, t_single, t_nulls, t_allnull and t_empty (only those a case uses),
-- each with k (row number), g (k modulo 2) and v of type VARCHAR. t_full holds six values
-- at the type's edges; t_single keeps the first; t_nulls blanks rows 1 and 4; t_allnull
-- is all NULL; t_empty has no rows.
CREATE TABLE t_full (k BIGINT, g BIGINT, v VARCHAR);
INSERT INTO t_full VALUES
    (0, 0, 'a'),
    (1, 1, 'b'),
    (2, 0, 'c'),
    (3, 1, 'd'),
    (4, 0, 'e'),
    (5, 1, 'f');
