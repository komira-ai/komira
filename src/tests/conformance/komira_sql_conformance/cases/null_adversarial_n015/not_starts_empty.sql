-- order: query
SELECT k FROM T WHERE NOT starts_with(s, '') ORDER BY k
