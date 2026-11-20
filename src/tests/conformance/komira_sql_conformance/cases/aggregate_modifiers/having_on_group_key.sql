-- order: rows
SELECT g AS gk, count(*) AS c FROM T GROUP BY g HAVING g = 'a'
