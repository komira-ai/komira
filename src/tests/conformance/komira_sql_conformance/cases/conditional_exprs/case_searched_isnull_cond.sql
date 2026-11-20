-- order: rows
SELECT k, CASE WHEN a IS NULL THEN 'isnull' ELSE 'notnull' END AS z FROM T
