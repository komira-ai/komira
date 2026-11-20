-- order: rows
-- pg_table_is_visible(zzz) as the group key
SELECT pg_table_is_visible(zzz) AS z, count(*) AS c FROM T GROUP BY pg_table_is_visible(zzz)
