-- order: query
SELECT k FROM T WHERE NOT (t = 'p1' AND contains(s,'z')) ORDER BY k
