-- order: rows
-- Aggregate shape over the exact-float table T, output columns g, numcust, tot
SELECT g, count(*) AS numcust, sum(price) AS tot FROM T WHERE price > 100.0 GROUP BY g
