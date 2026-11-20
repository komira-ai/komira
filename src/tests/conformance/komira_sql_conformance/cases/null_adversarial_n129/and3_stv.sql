-- order: query
SELECT k FROM T WHERE NOT (s LIKE 'z%' AND t = 'p1' AND v > 0) ORDER BY k
