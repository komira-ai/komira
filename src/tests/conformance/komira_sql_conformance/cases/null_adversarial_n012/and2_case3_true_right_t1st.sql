-- order: query
SELECT k FROM T WHERE NOT (t LIKE 'p%' AND s LIKE 'z%') ORDER BY k
