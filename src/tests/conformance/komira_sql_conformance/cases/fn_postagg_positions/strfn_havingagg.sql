-- order: rows
-- upper(max(s)) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING upper(max(s)) = 'ABC'
