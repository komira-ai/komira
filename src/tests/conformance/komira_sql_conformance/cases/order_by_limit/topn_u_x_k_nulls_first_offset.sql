-- order: query
-- total order (x, k DESC): the range crosses from NULLs to values
SELECT x, k FROM U ORDER BY x ASC NULLS FIRST, k DESC LIMIT 25 OFFSET 530
