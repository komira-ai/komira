-- quantile_cont at a quarter and three quarters per group of k, over an INTEGER
-- column and a DOUBLE column.
SELECT k, quantile_cont(i32, 0.25) AS q1, quantile_cont(i32, 0.75) AS q3, quantile_cont(v, 0.25) AS vq1, quantile_cont(v, 0.75) AS vq3 FROM nulls GROUP BY k ORDER BY k ASC NULLS FIRST
