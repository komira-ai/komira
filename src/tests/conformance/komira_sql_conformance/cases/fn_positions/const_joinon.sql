-- order: rows
-- pg_table_is_visible(zzz) in a join condition
SELECT T.k AS k FROM T JOIN U ON T.k = U.j AND pg_table_is_visible(zzz)
