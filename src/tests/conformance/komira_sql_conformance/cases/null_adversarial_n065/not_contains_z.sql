-- order: query
SELECT k FROM T WHERE NOT contains(s, 'z') ORDER BY k
