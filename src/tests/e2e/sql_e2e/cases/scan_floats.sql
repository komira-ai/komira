-- FLOAT and DOUBLE: -0.0, the least subnormal, the extremes, NaN and both infinities.
SELECT id, f32, f64, f32_special, f64_special FROM types ORDER BY id ASC NULLS LAST
