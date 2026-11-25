-- count(<column>) per group where groups 3 and 5 hold only NULLs. Catches a
-- group of NULLs dropped (it must give count 0, never no row), and a count
-- that reads the values under a NULL.
SELECT id, count(val) AS c, count(*) AS n FROM count_groups GROUP BY id ORDER BY id ASC NULLS LAST
