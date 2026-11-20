-- order: rows
-- agg mean 0key over a BIGINT column, empty rows
SELECT avg(v) AS a FROM t_empty
