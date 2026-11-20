-- order: rows
-- Aggregate shape over the exact-float table T, output columns k1, r, c
SELECT k1, sum(price * qty) AS r, count(*) AS c FROM T GROUP BY k1
