-- order: rows
-- Aggregate shape over the exact-float table T, output columns mx, mn, s
SELECT max(price) AS mx, min(price) AS mn, sum(price) AS s FROM T
