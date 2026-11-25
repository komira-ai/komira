-- coalesce over integer columns of different widths, signed and unsigned, and over a literal.
SELECT id, coalesce(i16, i32) AS a, coalesce(u8, i8) AS b, coalesce(i8, 100) AS c, coalesce(u32, i64) AS d, coalesce(i32, -100) AS e FROM types ORDER BY id ASC NULLS LAST
