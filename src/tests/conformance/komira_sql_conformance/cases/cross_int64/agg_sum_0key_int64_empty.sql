-- order: rows
-- agg sum 0key over a BIGINT column, empty rows
SELECT sum(v) AS s FROM t_empty
