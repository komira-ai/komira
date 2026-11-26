-- lag over a DOUBLE order key with NULLs placed last on a descending key, and
-- first on an ascending one, made total by id.
SELECT id, v, lag(id) OVER (ORDER BY v DESC NULLS LAST, id ASC NULLS LAST) AS prev_desc, lag(id, 2) OVER (ORDER BY v ASC NULLS FIRST, id ASC NULLS LAST) AS prev_asc FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
