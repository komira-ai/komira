-- coalesce and nullif over a BIGINT column.
SELECT id, coalesce(k, -100) AS c, nullif(k, 2) AS nk FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
