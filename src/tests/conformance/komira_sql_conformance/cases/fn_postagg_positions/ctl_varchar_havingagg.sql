-- order: rows
-- max(s) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING max(s) = 'abc'
