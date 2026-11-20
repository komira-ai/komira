-- order: rows
-- pg_table_is_visible(zzz) in a case result
SELECT k, CASE WHEN k < 3 THEN pg_table_is_visible(zzz) ELSE false END AS z FROM T
