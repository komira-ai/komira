-- A comparison filter over a column with NULLs.
SELECT id, i32 FROM nulls WHERE i32 > 0 ORDER BY id ASC NULLS LAST
