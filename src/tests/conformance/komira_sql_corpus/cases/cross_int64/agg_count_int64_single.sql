-- order: rows
-- agg count over a BIGINT column, single rows
SELECT v, count(*) AS n FROM t_single GROUP BY v
