-- Grouped sums of products after a join, one within the left side and one
-- across both sides. Catches a computed aggregate input refused or wrong
-- once it sits above a join.
SELECT l.k AS k, sum(l.a * l.b) AS sum_ab, sum(l.a * r.c) AS revenue FROM derived_l AS l JOIN derived_r AS r ON l.k = r.k GROUP BY l.k ORDER BY k ASC NULLS LAST
