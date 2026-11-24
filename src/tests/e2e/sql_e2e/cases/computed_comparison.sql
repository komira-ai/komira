-- A comparison as a value, NULL when an operand is NULL.
SELECT id, i32 = 0 AS eq, i32 <> 0 AS ne, i32 < v AS lt, s = '' AS empty FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
