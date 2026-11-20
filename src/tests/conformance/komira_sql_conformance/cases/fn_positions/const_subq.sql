-- order: rows
-- pg_table_is_visible(zzz) inside a scalar subquery
SELECT k, (SELECT max(pg_table_is_visible(zzz)) FROM T) AS z FROM T
