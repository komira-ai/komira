-- order: rows
-- filter over a DECIMAL(12,2) column, empty rows
SELECT k, g, v FROM t_empty WHERE v > CAST('30.75' AS DECIMAL(12,2))
