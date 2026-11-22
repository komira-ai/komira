-- order: query
SELECT k FROM T WHERE NOT (t LIKE 'p%' AND s LIKE '%') ORDER BY k
