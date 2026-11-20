-- order: rows
-- filter project over a DECIMAL(12,2) column, full rows
SELECT v FROM t_full WHERE v > CAST('30.75' AS DECIMAL(12,2))
