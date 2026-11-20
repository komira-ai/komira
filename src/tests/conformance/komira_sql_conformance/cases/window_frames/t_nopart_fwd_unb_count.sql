-- order: rows
-- a ROWS frame over a key with ties, broken by k so each row's frame is fixed
SELECT y FROM (SELECT k, count(v) OVER (ORDER BY o ASC NULLS LAST, k ASC NULLS LAST ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS y FROM T)
