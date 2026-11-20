-- order: rows
-- filter project over a TIMESTAMP column, single rows
SELECT v FROM t_single WHERE v > TIMESTAMP '2024-01-01 03:30:15.123456'
