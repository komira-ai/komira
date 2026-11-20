-- order: query
SELECT k FROM T WHERE NOT ends_with(s, 'z') ORDER BY k
