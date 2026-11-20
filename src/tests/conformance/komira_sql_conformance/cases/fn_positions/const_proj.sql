-- order: rows
-- pg_table_is_visible(zzz) in the select list
SELECT k, pg_table_is_visible(zzz) AS z FROM T
