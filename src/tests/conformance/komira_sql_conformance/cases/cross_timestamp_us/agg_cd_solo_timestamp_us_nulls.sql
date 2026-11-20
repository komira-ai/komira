-- order: rows
-- agg cd solo over a TIMESTAMP column, nulls rows
SELECT count(DISTINCT v) AS n FROM t_nulls
