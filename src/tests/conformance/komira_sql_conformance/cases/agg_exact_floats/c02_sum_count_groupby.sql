-- order: rows
-- Aggregate shape over the exact-float table T, output columns g, s, c
SELECT g, sum(price) AS s, count(*) AS c FROM T GROUP BY g
