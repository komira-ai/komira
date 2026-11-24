-- order: query
-- the range starts inside 541 NULLs
SELECT x FROM U ORDER BY x DESC NULLS FIRST LIMIT 50 OFFSET 500
