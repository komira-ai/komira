-- A two-argument aggregate whose second argument is computed
-- (corr(a, b + a * a)) beside one over plain columns, per group of three
-- rows; rounded, so the last bits of either engine's arithmetic do not
-- decide it. Catches the computed second argument refused or read as
-- another column (it would answer corr(a, b) or corr(a, a) = 1).
SELECT k, round(corr(a, b + a * a), 9) AS c_derived, round(corr(a, b), 9) AS c_plain FROM derived_l GROUP BY k ORDER BY k ASC NULLS LAST
