-- lag per partition, NULL at each partition's first row.
SELECT id, k, lag(id) OVER (PARTITION BY k ORDER BY id ASC NULLS LAST) AS prev FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
