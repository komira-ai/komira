-- order: rows
-- pg_table_is_visible(zzz) on a group key in having
SELECT k AS z FROM T GROUP BY k HAVING pg_table_is_visible(zzz)
