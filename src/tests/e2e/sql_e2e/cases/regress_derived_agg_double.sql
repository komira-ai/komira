-- A grouped sum of a computed DOUBLE input (every product exact). Catches
-- an aggregate over a computed float input refused or summed wrong once a
-- grouped sink folds DOUBLE.
SELECT c0, sum(f64_dict * 2.0) AS s2, count(*) AS n FROM floats GROUP BY c0 ORDER BY c0 ASC NULLS LAST
