-- TRY_CAST of text to DOUBLE and REAL: the correctly rounded value of each
-- width, NaN and the infinities in any case, a value past the range as an
-- infinity and one below it as a zero, NULL where the text is no number.
SELECT id, txt, TRY_CAST(txt AS DOUBLE) AS d, TRY_CAST(txt AS REAL) AS r FROM cast_text ORDER BY id ASC NULLS LAST
