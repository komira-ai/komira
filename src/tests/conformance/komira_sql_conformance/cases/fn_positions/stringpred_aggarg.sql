-- order: rows
-- starts_with(s, 'a') as an aggregate argument
SELECT max(starts_with(s, 'a')) AS z FROM T
