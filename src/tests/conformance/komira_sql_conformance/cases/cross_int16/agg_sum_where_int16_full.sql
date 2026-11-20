-- order: rows
-- agg sum where over a SMALLINT column, full rows
SELECT sum(v) AS s FROM t_full WHERE k > 2
