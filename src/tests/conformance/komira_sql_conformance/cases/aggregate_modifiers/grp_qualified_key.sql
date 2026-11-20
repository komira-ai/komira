-- order: rows
SELECT T.g AS gk, count(*) AS c FROM T GROUP BY T.g
