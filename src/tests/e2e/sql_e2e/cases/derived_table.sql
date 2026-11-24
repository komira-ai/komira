-- A subquery in FROM.
SELECT k, n * 2 AS twice FROM (SELECT k, count(*) AS n FROM nulls GROUP BY k) AS g ORDER BY k ASC NULLS FIRST
