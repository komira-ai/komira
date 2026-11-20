-- order: rows
SELECT g AS gk, count(*) AS c FROM T WHERE k < 0 GROUP BY g
