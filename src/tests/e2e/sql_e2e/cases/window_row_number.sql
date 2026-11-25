-- row_number per partition.
SELECT id, k, row_number() OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) AS rn FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
