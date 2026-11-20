-- order: query
-- sqrt(g) as the sort key
SELECT k, sqrt(g) AS z FROM T ORDER BY sqrt(g)
