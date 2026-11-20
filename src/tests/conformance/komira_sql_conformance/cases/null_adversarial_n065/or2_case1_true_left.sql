-- order: query
SELECT k FROM T WHERE NOT (s LIKE '%' OR t = 'p1') ORDER BY k
