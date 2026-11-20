-- order: rows
-- pg_table_is_visible(zzz) in the where clause
SELECT k FROM T WHERE pg_table_is_visible(zzz)
