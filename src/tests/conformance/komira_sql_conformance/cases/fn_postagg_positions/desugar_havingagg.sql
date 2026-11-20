-- order: rows
-- isnan(sum(f)) around an aggregate in having
SELECT (k < 4) AS grp FROM T GROUP BY (k < 4) HAVING isnan(sum(f))
