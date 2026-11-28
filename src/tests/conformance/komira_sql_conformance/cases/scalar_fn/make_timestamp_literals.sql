-- order: rows
-- six-argument make_timestamp of constants: fractions, 60 seconds, 24:00, sub-microsecond rounding
SELECT k, make_timestamp(2024, 2, 29, 1, 2, 3.5), make_timestamp(2024, 2, 29, 23, 59, 60), make_timestamp(2015, 12, 31, 24, 0, 0), make_timestamp(2028, 2, 29, 0, 0, 0.0000005), make_timestamp(2000, 2, 29, 12, 0, 59.9999995) FROM T
