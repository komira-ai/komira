-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'qq%' AND t LIKE 'p%') ORDER BY k
