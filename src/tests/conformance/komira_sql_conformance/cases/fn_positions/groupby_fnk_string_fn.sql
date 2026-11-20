-- order: rows
-- upper(s) as the group key
SELECT upper(s) AS z, count(*) AS c FROM T GROUP BY upper(s)
