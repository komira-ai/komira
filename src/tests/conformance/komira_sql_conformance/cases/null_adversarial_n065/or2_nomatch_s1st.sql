-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'q%' OR t = 'p9') ORDER BY k
