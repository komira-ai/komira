-- order: query
-- a deep offset over a total order
SELECT x, k FROM U ORDER BY x ASC NULLS LAST, k LIMIT 5 OFFSET 9990
