-- order: query
SELECT k FROM T WHERE NOT (s LIKE '%' AND t LIKE 'p%') ORDER BY k
