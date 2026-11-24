-- order: query
-- total order (a DESC NULLS LAST, k): the rows are fixed
SELECT a, k FROM T ORDER BY a DESC NULLS LAST, k LIMIT 4 OFFSET 2
