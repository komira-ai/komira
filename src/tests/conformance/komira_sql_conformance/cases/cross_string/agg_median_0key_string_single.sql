-- order: rows
-- agg median 0key over a VARCHAR column, single rows
SELECT median(v) AS m FROM t_single
