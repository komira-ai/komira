-- order: rows
-- agg sum where over a BIGINT column, single rows
SELECT sum(v) AS s FROM t_single WHERE k > 2
