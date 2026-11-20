-- order: query
-- Surface probe: count with nulls
SELECT k, count(i) AS i FROM fx_nulls GROUP BY k ORDER BY k
