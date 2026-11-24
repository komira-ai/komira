-- The same floats through a filter on another column (c0 >= 45 keeps 600
-- rows across all three row groups). Catches float values misaligned with
-- the rows the filter keeps.
SELECT i, c0, f64, f32, f64_dict, f32_dict FROM floats WHERE c0 >= 45 ORDER BY i ASC NULLS LAST
