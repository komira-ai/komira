-- A CTE read twice.
WITH g AS (SELECT k, count(*) AS n FROM nulls GROUP BY k) SELECT a.k AS k, a.n AS n, b.n AS n2 FROM g AS a JOIN g AS b ON a.k = b.k ORDER BY k ASC NULLS FIRST
