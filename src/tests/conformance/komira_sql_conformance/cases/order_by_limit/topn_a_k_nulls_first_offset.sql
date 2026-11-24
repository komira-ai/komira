-- order: query
-- total order (a, k): the rows are fixed, k is shown
SELECT a, k FROM T ORDER BY a ASC NULLS FIRST, k DESC LIMIT 5 OFFSET 3
