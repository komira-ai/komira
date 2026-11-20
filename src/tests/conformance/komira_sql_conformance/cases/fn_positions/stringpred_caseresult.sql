-- order: rows
-- starts_with(s, 'a') in a case result
SELECT k, CASE WHEN k < 3 THEN starts_with(s, 'a') ELSE false END AS z FROM T
