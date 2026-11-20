-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'q%' AND t = 'p1') ORDER BY k
