-- order: query
SELECT k FROM T WHERE NOT (v > 1000 OR s LIKE 'z%' OR t = 'p9') ORDER BY k
