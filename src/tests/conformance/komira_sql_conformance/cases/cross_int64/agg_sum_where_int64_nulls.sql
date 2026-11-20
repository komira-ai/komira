-- order: rows
-- agg sum where over a BIGINT column, nulls rows
SELECT sum(v) AS s FROM t_nulls WHERE k > 2
