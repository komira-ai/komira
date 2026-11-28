-- nullif over an INTEGER column, greatest and least over, and CASE with arms of, different integer widths.
SELECT id, nullif(i32, 0) AS n, greatest(i16, i32) AS g, least(u16, i8) AS l, CASE WHEN id < 100 THEN i16 ELSE i32 END AS c FROM types ORDER BY id ASC NULLS LAST
