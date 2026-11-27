-- median over an even count: two non-NULL values, the mean of the pair.
SELECT median(i32) AS med, count(i32) AS n FROM nulls WHERE id < 3 ORDER BY med ASC NULLS LAST
