-- order: rows
-- Aggregate shape over the exact-float table T, output columns g, c
SELECT g, corr(price, qty) AS c FROM T GROUP BY g
