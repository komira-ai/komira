-- order: rows
-- strpos(max(s), 'b') around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING strpos(max(s), 'b') > 0
