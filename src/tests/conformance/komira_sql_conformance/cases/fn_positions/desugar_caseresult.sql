-- order: rows
-- isnan(f) in a case result
SELECT k, CASE WHEN k < 3 THEN isnan(f) ELSE false END AS z FROM T
