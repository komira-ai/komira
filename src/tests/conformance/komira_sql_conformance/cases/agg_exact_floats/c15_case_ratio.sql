-- order: rows
-- Aggregate shape over the exact-float table T, output columns r
SELECT sum(CASE WHEN k1 = 'A' THEN price ELSE 0.0 END) / sum(price) AS r FROM T
