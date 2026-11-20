-- order: query
SELECT k FROM T WHERE NOT (t = 'p1' AND s LIKE 'z%') ORDER BY k
