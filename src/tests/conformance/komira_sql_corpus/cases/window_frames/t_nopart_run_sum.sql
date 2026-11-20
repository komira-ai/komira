-- order: rows
-- a ROWS frame over a key with ties; only the multiset of answers is fixed
SELECT y FROM (SELECT k, sum(v) OVER (ORDER BY o ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS y FROM T)
