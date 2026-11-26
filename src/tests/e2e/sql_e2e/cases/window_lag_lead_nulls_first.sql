-- lag and lead over an order key with NULLs placed first, ascending and
-- descending, made total by id within each partition.
SELECT id, k, i32, lag(id) OVER (PARTITION BY k ORDER BY i32 ASC NULLS FIRST, id ASC NULLS LAST) AS prev, lead(id) OVER (PARTITION BY k ORDER BY i32 DESC NULLS FIRST, id DESC NULLS LAST) AS next FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
