-- order: rows
-- scalar subquery with an empty result -> null, projected
SELECT k, (SELECT max(j) FROM U WHERE j > 100) AS m FROM T
