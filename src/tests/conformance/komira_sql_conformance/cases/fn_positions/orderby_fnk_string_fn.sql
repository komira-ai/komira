-- order: query
-- upper(s) as the sort key
SELECT k, upper(s) AS z FROM T ORDER BY upper(s)
