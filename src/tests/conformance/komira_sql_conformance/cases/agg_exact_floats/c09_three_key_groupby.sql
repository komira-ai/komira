-- order: rows
-- Aggregate shape over the exact-float table T, output columns k1, k2, g, r
SELECT k1, k2, g, sum(dp) AS r FROM T GROUP BY k1, k2, g
