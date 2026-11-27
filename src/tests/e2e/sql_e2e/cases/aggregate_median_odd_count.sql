-- median over an odd count: three non-NULL values, the middle one.
SELECT median(i32) AS med, count(i32) AS n FROM nulls WHERE id < 5 ORDER BY med ASC NULLS LAST
