-- order: rows
-- Aggregate shape over the exact-float table T, output columns g, s
SELECT g, sum(price) AS s FROM T GROUP BY g
