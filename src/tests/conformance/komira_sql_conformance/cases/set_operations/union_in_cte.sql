-- order: rows
WITH u AS (SELECT k FROM ta UNION SELECT k FROM tb) SELECT count(*) AS c FROM u
