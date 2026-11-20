-- order: rows
-- starts_with(max(s), 'a') around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING starts_with(max(s), 'a')
