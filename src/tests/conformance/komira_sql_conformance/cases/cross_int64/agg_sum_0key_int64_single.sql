-- order: rows
-- agg sum 0key over a BIGINT column, single rows
SELECT sum(v) AS s FROM t_single
