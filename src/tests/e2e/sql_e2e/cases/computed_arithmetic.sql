-- +, -, * and unary minus over INTEGER with NULLs.
SELECT id, i32 + 1 AS plus, i32 - 3 AS minus, i32 * 2 AS times, -i32 AS neg FROM nulls WHERE id < 300 ORDER BY id ASC NULLS LAST
