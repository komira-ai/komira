-- order: rows
-- sign(min(i)) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING sign(min(i)) < 0
