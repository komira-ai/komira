-- order: rows
-- isnan(f) on a group key in having
SELECT f AS z FROM T GROUP BY f HAVING isnan(f)
