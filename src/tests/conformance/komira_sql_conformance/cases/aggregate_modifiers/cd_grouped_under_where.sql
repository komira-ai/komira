-- order: rows
SELECT g AS gk, count(DISTINCT v) AS cd FROM T WHERE k <= 6 GROUP BY g
