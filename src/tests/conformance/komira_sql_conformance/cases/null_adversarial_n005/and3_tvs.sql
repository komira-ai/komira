-- order: query
SELECT k FROM T WHERE NOT (t = 'p1' AND v > 0 AND s LIKE 'z%') ORDER BY k
