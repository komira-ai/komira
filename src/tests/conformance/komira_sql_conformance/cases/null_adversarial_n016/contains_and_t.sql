-- order: query
SELECT k FROM T WHERE NOT (contains(s,'z') AND t = 'p1') ORDER BY k
