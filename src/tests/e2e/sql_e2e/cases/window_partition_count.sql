-- A window aggregate over each whole partition, every row kept.
SELECT id, k, count(*) OVER (PARTITION BY k) AS n FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
