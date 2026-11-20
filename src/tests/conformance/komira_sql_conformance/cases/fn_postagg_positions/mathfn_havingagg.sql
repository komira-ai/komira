-- order: rows
-- sqrt(sum(g)) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING sqrt(sum(g)) > 2.0
