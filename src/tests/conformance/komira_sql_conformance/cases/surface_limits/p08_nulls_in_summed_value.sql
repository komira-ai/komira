-- order: query
-- Surface probe: nulls in summed value
SELECT k, sum(i) AS i FROM fx_nulls GROUP BY k ORDER BY k
