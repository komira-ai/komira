-- quantile_cont at 0, a quarter, a half, three quarters and 1 over an INTEGER
-- column and a DOUBLE column holding NULLs, no group.
SELECT quantile_cont(i32, 0.25) AS q1, quantile_cont(i32, 0.75) AS q3, quantile_cont(i32, 0.5) AS q2, quantile_cont(i32, 0) AS q0, quantile_cont(i32, 1) AS q4, quantile_cont(v, 0.25) AS vq1, quantile_cont(v, 0.75) AS vq3 FROM nulls ORDER BY q1 ASC NULLS LAST
