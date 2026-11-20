-- order: rows
-- agg sum where over a DECIMAL(12,2) column, full rows
SELECT sum(v) AS s FROM t_full WHERE k > 2
