-- order: rows
-- regexp_extract(max(s), '[a-z]+') around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING regexp_extract(max(s), '[a-z]+') = 'abc'
