-- order: rows
-- Aggregate shape over the exact-float table T, output columns k1, k2, revenue, c
SELECT k1, k2, sum(dp) AS revenue, count(*) AS c FROM T WHERE qty >= 10.0 GROUP BY k1, k2
