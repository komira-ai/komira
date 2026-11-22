-- order: rows
-- starts_with(s, 'a') on a group key in having
SELECT s AS z FROM T GROUP BY s HAVING starts_with(s, 'a')
