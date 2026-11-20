-- order: rows
-- agg median 0key over a BIGINT column, single rows
SELECT median(v) AS m FROM t_single
