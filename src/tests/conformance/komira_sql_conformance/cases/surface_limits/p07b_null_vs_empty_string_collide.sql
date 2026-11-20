-- order: query
-- Surface probe: null vs empty string collide
SELECT k, sum(v) AS v FROM fx_nullvsempty GROUP BY k ORDER BY k
