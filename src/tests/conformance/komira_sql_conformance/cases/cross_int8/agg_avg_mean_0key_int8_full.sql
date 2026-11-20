-- order: rows
-- agg avg mean 0key over a TINYINT column, full rows
SELECT avg(v) AS a, mean(v) AS m FROM t_full
