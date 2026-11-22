-- order: query
SELECT k FROM T WHERE NOT (v > 0 AND s LIKE 'z%' AND t = 'p1') ORDER BY k
