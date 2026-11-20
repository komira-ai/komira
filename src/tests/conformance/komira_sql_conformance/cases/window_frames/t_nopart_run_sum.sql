-- order: rows
-- a ROWS frame over a key with ties, broken by k so each row's frame is fixed
SELECT y FROM (SELECT k, sum(v) OVER (ORDER BY o ASC NULLS LAST, k ASC NULLS LAST ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS y FROM T)
