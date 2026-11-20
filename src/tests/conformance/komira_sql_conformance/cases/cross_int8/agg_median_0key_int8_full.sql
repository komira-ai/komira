-- order: rows
-- agg median 0key over a TINYINT column, full rows
SELECT median(v) AS m FROM t_full
