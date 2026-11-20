-- order: rows
-- a plain column as the group key
SELECT s AS z, count(*) AS c FROM T GROUP BY s
