-- order: rows
-- agg mean 0key over a DECIMAL(12,2) column, empty rows
SELECT avg(v) AS a FROM t_empty
