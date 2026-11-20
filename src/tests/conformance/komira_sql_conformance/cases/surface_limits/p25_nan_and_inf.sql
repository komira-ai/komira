-- order: query
-- Surface probe: nan and inf
SELECT k, sum(v) AS v FROM fx_nanfloat GROUP BY k ORDER BY k
