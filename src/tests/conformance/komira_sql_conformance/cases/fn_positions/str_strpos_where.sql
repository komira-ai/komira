-- order: rows
-- non-ascii through strpos() in where
SELECT k FROM T WHERE strpos(s, 'b') > 2
