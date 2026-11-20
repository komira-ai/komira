-- order: query
-- pg_table_is_visible(zzz) as the sort key
SELECT k, pg_table_is_visible(zzz) AS z FROM T ORDER BY pg_table_is_visible(zzz)
