-- order: query
-- 20000 rows, key only, ties at the cut
SELECT x FROM U ORDER BY x ASC NULLS LAST LIMIT 20 OFFSET 3000
