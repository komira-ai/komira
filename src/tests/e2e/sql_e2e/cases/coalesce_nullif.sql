-- coalesce and nullif.
SELECT id, coalesce(i32, -100) AS c, nullif(k, 2) AS nk FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
