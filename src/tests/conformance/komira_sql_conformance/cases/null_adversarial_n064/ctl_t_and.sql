-- order: query
SELECT k FROM T WHERE NOT (t = 'p1' AND t LIKE 'p%') ORDER BY k
