-- DOUBLE and FLOAT over three row groups, stored PLAIN and dictionary
-- encoded, with NaN, both infinities, -0.0 and 0.0 first. Catches a scan
-- that changes a value, a row's place or a column's type at a row-group
-- boundary or under either encoding.
SELECT i, c0, f64, f32, f64_dict, f32_dict FROM floats ORDER BY i ASC NULLS LAST
