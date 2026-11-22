-- order: rows
-- bool_or(bt) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING bool_or(bt)
