-- order: rows
-- Aggregate shape over the exact-float table T, output columns r
SELECT sum(price) AS r FROM T WHERE (k1 = 'A' AND qty <= 11.0) OR (k1 = 'N' AND qty >= 20.0)
