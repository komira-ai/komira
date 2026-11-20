-- order: rows
-- agg sum 0key over a DECIMAL(12,2) column, full rows
SELECT sum(v) AS s FROM t_full
