-- order: rows
-- multiply(sum(k), 3) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING multiply(sum(k), 3) > 9
