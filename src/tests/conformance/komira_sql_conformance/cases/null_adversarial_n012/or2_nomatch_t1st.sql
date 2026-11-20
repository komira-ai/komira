-- order: query
SELECT k FROM T WHERE NOT (t = 'p9' OR s LIKE 'q%') ORDER BY k
