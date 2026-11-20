-- order: rows
SELECT IFNULL(s, 'D') AS g, count(*) AS n FROM T GROUP BY IFNULL(s, 'D')
