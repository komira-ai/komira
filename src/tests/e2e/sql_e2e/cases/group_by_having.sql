-- HAVING over an aggregate.
SELECT k, count(*) AS n FROM nulls GROUP BY k HAVING count(*) > 1000 ORDER BY k ASC NULLS FIRST
