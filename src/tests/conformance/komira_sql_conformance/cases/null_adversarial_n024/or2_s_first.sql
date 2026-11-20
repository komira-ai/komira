-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%' OR t = 'p9') ORDER BY k
