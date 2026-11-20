-- order: query
SELECT k FROM T WHERE NOT starts_with(s, 'z') ORDER BY k
