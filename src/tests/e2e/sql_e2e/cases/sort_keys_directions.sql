-- Three sort keys, each with its own direction and NULL placement.
SELECT id, k, i32 FROM nulls WHERE id < 300 ORDER BY k DESC NULLS FIRST, i32 ASC NULLS LAST, id DESC NULLS LAST
