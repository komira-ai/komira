-- order: rows
-- agg count col 0key over a DECIMAL(12,2) column, nulls rows
SELECT count(v) AS c FROM t_nulls
