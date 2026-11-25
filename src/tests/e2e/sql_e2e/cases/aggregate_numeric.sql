-- sum, min and max over an INTEGER and a DOUBLE of quarters, no group.
SELECT sum(i32) AS si, sum(v) AS sv, min(i32) AS mi, max(v) AS mv FROM nulls ORDER BY mi ASC NULLS LAST
