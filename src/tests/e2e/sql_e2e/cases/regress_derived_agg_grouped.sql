-- Grouped sums of a column, a product and a deeper product. Catches an
-- aggregate over a computed input refused or summed wrong, and a plain
-- column aggregate beside it disturbed.
SELECT k, sum(a) AS sum_a, sum(a * b) AS sum_ab, sum(a * b * b) AS sum_abb FROM derived_l GROUP BY k ORDER BY k ASC NULLS LAST
