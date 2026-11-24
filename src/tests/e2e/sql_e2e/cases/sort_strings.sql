-- Strings in byte order, NULLs first.
SELECT id, str FROM types ORDER BY str ASC NULLS FIRST, id ASC NULLS LAST
