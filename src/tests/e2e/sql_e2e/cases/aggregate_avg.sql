-- avg of an INTEGER and of a DOUBLE of quarters.
SELECT avg(i32) AS ai, avg(v) AS av FROM nulls ORDER BY ai ASC NULLS LAST
