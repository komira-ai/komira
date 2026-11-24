-- sum, min and max over integers, doubles and strings.
SELECT sum(i32) AS si, sum(v) AS sv, min(i32) AS mi, max(v) AS mv, min(s) AS ms, max(s) AS xs FROM nulls ORDER BY si ASC NULLS LAST
