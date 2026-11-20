-- order: rows
-- pg_table_is_visible(zzz) as an aggregate argument
SELECT max(pg_table_is_visible(zzz)) AS z FROM T
