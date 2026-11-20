-- order: query
-- Surface probe: int64 overflow sum
SELECT k, sum(i) AS i FROM fx_bigint GROUP BY k ORDER BY k
