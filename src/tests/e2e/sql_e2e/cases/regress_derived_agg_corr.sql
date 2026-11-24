-- A two-argument aggregate whose second argument is computed (corr(a, 2b))
-- beside one over plain columns, per group; rounded, so the last bits of
-- either engine's arithmetic do not decide it. Catches the computed second
-- argument refused or read as another column.
SELECT k, round(corr(a, b * 2.0), 9) AS c_derived, round(corr(a, b), 9) AS c_plain FROM derived_l GROUP BY k ORDER BY k ASC NULLS LAST
