-- order: query
SELECT k FROM T WHERE NOT (s = 'zap' AND t LIKE 'p%') ORDER BY k
