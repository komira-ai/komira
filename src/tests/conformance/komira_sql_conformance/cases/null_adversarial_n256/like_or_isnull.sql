-- order: query
SELECT k FROM T WHERE s LIKE 'z%' OR s IS NULL ORDER BY k
