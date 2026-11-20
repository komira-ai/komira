-- order: rows
-- filter project over a DECIMAL(12,2) column, empty rows
SELECT v FROM t_empty WHERE v > CAST('30.75' AS DECIMAL(12,2))
