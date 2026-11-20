-- order: rows
-- pow(sum(n), 2) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING pow(sum(n), 2) > 4.0
