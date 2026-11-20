-- order: rows
-- agg count over a BIGINT column, nulls rows
SELECT v, count(*) AS n FROM t_nulls GROUP BY v
