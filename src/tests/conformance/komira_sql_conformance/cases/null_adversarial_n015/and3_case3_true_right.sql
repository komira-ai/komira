-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%' AND t LIKE 'p%' AND v > 0) ORDER BY k
