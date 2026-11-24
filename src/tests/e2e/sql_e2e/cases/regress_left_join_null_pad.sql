-- LEFT JOIN on INT64 keys, probe keys 0..7 against build keys 0..3.
-- Catches the build payload not NULL on exactly the unmatched rows (4..7),
-- or wrong on a matched one.
SELECT p.key AS key, p.left_val AS left_val, b.right_val AS right_val FROM pad_probe AS p LEFT JOIN pad_build AS b ON p.key = b.key ORDER BY key ASC NULLS LAST
