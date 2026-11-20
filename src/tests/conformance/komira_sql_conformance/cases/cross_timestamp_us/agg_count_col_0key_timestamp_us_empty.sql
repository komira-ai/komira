-- order: rows
-- agg count col 0key over a TIMESTAMP column, empty rows
SELECT count(v) AS c FROM t_empty
