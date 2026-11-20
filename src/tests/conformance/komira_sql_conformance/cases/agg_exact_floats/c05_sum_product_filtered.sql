-- order: rows
-- Aggregate shape over the exact-float table T, output columns r
SELECT sum(price * disc) AS r FROM T WHERE disc >= 0.0625 AND disc <= 0.1875 AND qty < 24.0
