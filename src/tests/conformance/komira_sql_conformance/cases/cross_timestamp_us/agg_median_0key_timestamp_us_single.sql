-- order: rows
-- agg median 0key over a TIMESTAMP column, single rows
SELECT median(v) AS m FROM t_single
