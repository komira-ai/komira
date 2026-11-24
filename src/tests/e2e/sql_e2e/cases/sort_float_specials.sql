-- DOUBLE with NaN (greatest), both infinities and -0.0 equal to 0.0.
SELECT id, f64_special FROM types ORDER BY f64_special ASC NULLS LAST, id ASC NULLS LAST
