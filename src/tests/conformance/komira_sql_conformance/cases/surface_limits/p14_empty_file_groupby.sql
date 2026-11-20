-- order: query
-- Surface probe: empty file groupby
SELECT k, sum(v) AS v FROM fx_empty GROUP BY k ORDER BY k
