-- order: rows
-- Aggregate shape over the exact-float table T, output columns g, m, sd
SELECT g, median(qty) AS m, stddev(qty) AS sd FROM T GROUP BY g
