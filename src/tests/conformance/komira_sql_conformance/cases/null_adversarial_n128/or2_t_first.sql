-- order: query
SELECT k FROM T WHERE NOT (t = 'p9' OR s LIKE 'z%') ORDER BY k
