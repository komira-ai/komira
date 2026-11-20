-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%') OR s IS NULL ORDER BY k
