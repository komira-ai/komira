-- order: rows
SELECT count(*) AS c FROM (SELECT k FROM ta UNION SELECT k FROM tb) d
