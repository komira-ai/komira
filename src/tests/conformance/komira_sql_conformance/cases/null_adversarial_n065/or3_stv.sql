-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%' OR t = 'p9' OR v > 1000) ORDER BY k
