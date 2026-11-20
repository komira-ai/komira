-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%' AND t LIKE 'p%') ORDER BY k
