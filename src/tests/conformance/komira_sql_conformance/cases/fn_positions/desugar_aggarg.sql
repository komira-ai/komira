-- order: rows
-- isnan(f) as an aggregate argument
SELECT max(isnan(f)) AS z FROM T
