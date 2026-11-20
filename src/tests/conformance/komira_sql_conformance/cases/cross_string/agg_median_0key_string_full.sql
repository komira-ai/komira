-- order: rows
-- agg median 0key over a VARCHAR column, full rows
SELECT median(v) AS m FROM t_full
