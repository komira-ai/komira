-- order: rows
-- agg sum 0key over a UTINYINT column, full rows
SELECT sum(v) AS s FROM t_full
