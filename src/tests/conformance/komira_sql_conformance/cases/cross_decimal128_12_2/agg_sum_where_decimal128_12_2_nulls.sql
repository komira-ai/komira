-- order: rows
-- agg sum where over a DECIMAL(12,2) column, nulls rows
SELECT sum(v) AS s FROM t_nulls WHERE k > 2
