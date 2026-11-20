-- order: query
SELECT k FROM T WHERE NOT (NOT (s LIKE 'z%')) ORDER BY k
