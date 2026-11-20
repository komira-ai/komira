-- order: rows
-- agg count col 0key over a BIGINT column, empty rows
SELECT count(v) AS c FROM t_empty
