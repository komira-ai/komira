-- order: rows
SELECT g AS gk FROM T GROUP BY g HAVING count(*) > 2
