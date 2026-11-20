-- order: rows
-- month(max(t)) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING month(max(t)) > 5
