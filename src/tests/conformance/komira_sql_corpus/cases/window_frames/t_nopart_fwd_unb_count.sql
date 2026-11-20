-- order: rows
-- a ROWS frame over a key with ties; only the multiset of answers is fixed
SELECT y FROM (SELECT k, count(v) OVER (ORDER BY o ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS y FROM T)
