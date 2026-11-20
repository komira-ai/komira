-- order: rows
-- agg median 0key over a BOOLEAN column, single rows
SELECT median(v) AS m FROM t_single
