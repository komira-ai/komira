-- order: rows
SELECT count(DISTINCT v) AS cd, sum(v) AS s, count(*) AS c FROM T
