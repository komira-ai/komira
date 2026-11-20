-- order: rows
-- two different uncorrelated scalar subqueries in one select list
SELECT k, (SELECT max(j) FROM U) AS a, (SELECT min(j) FROM U) AS b FROM T
