-- order: query
-- Surface probe: nulls in group key
SELECT k, sum(v) AS v FROM fx_nulls GROUP BY k ORDER BY k
