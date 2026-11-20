-- order: rows
-- Aggregate shape over the exact-float table T, output columns g, a1, a2, a3
SELECT g, avg(price) AS a1, avg(qty) AS a2, avg(disc) AS a3 FROM T GROUP BY g
