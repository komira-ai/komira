-- count(DISTINCT) with no GROUP BY over 11 rows. Catches rows counted for
-- distinct values and a NULL counted as a value.
SELECT count(DISTINCT val) AS cd_val, count(DISTINCT key) AS cd_key, count(*) AS n FROM distinct_pairs ORDER BY cd_val ASC NULLS LAST
