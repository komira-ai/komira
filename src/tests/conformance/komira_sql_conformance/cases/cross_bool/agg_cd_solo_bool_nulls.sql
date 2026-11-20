-- order: rows
-- agg cd solo over a BOOLEAN column, nulls rows
SELECT count(DISTINCT v) AS n FROM t_nulls
