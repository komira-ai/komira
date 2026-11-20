-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%') AND s IS NOT NULL ORDER BY k
