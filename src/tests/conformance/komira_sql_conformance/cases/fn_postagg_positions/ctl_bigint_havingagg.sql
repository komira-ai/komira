-- order: rows
-- sum(k) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING sum(k) > 4
