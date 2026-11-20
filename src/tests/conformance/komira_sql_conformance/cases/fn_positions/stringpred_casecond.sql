-- order: rows
-- starts_with(s, 'a') in a case condition
SELECT k, CASE WHEN starts_with(s, 'a') THEN 'y' ELSE 'n' END AS z FROM T
