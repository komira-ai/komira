-- order: query
-- Surface probe: unicode and quotes
SELECT k, sum(v) AS v FROM fx_weirdstr GROUP BY k ORDER BY k
