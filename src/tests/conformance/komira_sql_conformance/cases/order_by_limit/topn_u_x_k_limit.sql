-- order: query
-- plain top-N over a total order
SELECT x, k FROM U ORDER BY x ASC NULLS LAST, k LIMIT 100
