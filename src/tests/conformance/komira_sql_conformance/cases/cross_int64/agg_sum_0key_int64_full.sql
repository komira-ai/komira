-- order: rows
-- agg sum 0key over a BIGINT column, full rows
SELECT sum(v) AS s FROM t_full
