-- UNION ALL of two BIGINT columns, duplicates and NULLs kept.
SELECT k FROM join_left UNION ALL SELECT k FROM join_right ORDER BY k ASC NULLS FIRST
