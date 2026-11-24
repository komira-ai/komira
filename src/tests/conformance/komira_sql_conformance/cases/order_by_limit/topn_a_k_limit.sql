-- order: query
-- plain top-N over a total order
SELECT a, k FROM T ORDER BY a ASC NULLS LAST, k LIMIT 6
