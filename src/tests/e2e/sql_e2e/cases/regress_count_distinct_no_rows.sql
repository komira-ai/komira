-- count(DISTINCT) over no row: one row, 0 (not NULL, not no row).
SELECT count(DISTINCT val) AS cd, count(*) AS n FROM distinct_pairs WHERE key < 0 ORDER BY cd ASC NULLS LAST
