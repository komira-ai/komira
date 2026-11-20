-- order: rows
-- Aggregate shape over the exact-float table T, output columns r
SELECT sum(price) / 7.0 AS r FROM T WHERE qty < 24.0
