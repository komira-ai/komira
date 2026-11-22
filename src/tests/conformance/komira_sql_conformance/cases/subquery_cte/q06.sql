-- order: rows
-- the same uncorrelated scalar subquery twice in one select list
SELECT k, (SELECT max(j) FROM U) AS a, (SELECT max(j) FROM U) AS b FROM T
