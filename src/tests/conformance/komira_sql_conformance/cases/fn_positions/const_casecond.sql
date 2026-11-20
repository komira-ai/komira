-- order: rows
-- pg_table_is_visible(zzz) in a case condition
SELECT k, CASE WHEN pg_table_is_visible(zzz) THEN 'y' ELSE 'n' END AS z FROM T
