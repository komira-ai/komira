-- order: rows
-- Aggregate shape over the exact-float table T, output columns k1, r
SELECT k1, sum(price * (1 - disc)) AS r FROM T GROUP BY k1
