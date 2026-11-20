-- Tables named t_full, t_single, t_nulls, t_allnull and t_empty (only those a case uses),
-- each with k (row number), g (k modulo 2) and v of type TIMESTAMP. t_full holds six values
-- at the type's edges; t_single keeps the first; t_nulls blanks rows 1 and 4; t_allnull
-- is all NULL; t_empty has no rows.
CREATE TABLE t_full (k BIGINT, g BIGINT, v TIMESTAMP);
INSERT INTO t_full VALUES
    (0, 0, TIMESTAMP '2024-01-01 01:30:15.123456'),
    (1, 1, TIMESTAMP '2024-01-01 02:30:15.123456'),
    (2, 0, TIMESTAMP '2024-01-01 03:30:15.123456'),
    (3, 1, TIMESTAMP '2024-01-01 04:30:15.123456'),
    (4, 0, TIMESTAMP '2024-01-01 05:30:15.123456'),
    (5, 1, TIMESTAMP '2024-01-01 06:30:15.123456');
CREATE TABLE t_single (k BIGINT, g BIGINT, v TIMESTAMP);
INSERT INTO t_single VALUES
    (0, 0, TIMESTAMP '2024-01-01 01:30:15.123456');
CREATE TABLE t_nulls (k BIGINT, g BIGINT, v TIMESTAMP);
INSERT INTO t_nulls VALUES
    (0, 0, TIMESTAMP '2024-01-01 01:30:15.123456'),
    (1, 1, NULL),
    (2, 0, TIMESTAMP '2024-01-01 03:30:15.123456'),
    (3, 1, TIMESTAMP '2024-01-01 04:30:15.123456'),
    (4, 0, NULL),
    (5, 1, TIMESTAMP '2024-01-01 06:30:15.123456');
CREATE TABLE t_allnull (k BIGINT, g BIGINT, v TIMESTAMP);
INSERT INTO t_allnull VALUES
    (0, 0, NULL),
    (1, 1, NULL),
    (2, 0, NULL),
    (3, 1, NULL),
    (4, 0, NULL),
    (5, 1, NULL);
CREATE TABLE t_empty (k BIGINT, g BIGINT, v TIMESTAMP);
