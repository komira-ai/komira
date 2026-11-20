-- Thirteen rows of numeric edge values, one row per edge, with two operand columns
-- per integer width (signed and unsigned, 8 to 64 bits): minimum, maximum,
-- zero divisors, negative divisors, NULL, and 2^53+1 in the 64-bit column.
-- Float columns hold zero of both signs, infinities, NaN, the smallest
-- subnormal and normal, the largest finite value, and 0.1 against 0.2.
-- Floats are quoted literals cast to the column type so -0.0 keeps its sign;
-- d1 is a column of exact 1.0 so a multiply isolates the integer to double step.
CREATE TABLE T (k BIGINT, i8a TINYINT, i8b TINYINT, i16a SMALLINT, i16b SMALLINT, i32a INTEGER, i32b INTEGER, i64a BIGINT, i64b BIGINT, u8a UTINYINT, u8b UTINYINT, u16a USMALLINT, u16b USMALLINT, u32a UINTEGER, u32b UINTEGER, u64a UBIGINT, u64b UBIGINT, f64 DOUBLE, g64 DOUBLE, f32 FLOAT, d1 DOUBLE);
INSERT INTO T VALUES
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, '0.0'::DOUBLE, '0.0'::DOUBLE, '0.0'::FLOAT, '1.0'::DOUBLE),
    (1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, '1.0'::DOUBLE, '0.0'::DOUBLE, '1.0'::FLOAT, '1.0'::DOUBLE),
    (2, 127, 1, 32767, 1, 2147483647, 1, 9223372036854775807, 1, 255, 1, 65535, 1, 4294967295, 1, 18446744073709551615, 1, '1.0'::DOUBLE, '-0.0'::DOUBLE, '1.0'::FLOAT, '1.0'::DOUBLE),
    (3, -128, 1, -32768, 1, -2147483648, 1, -9223372036854775808, 1, 0, 1, 0, 1, 0, 1, 0, 1, '-0.0'::DOUBLE, '1.0'::DOUBLE, '-0.0'::FLOAT, '1.0'::DOUBLE),
    (4, -128, -1, -32768, -1, -2147483648, -1, -9223372036854775808, -1, 0, 255, 0, 65535, 0, 4294967295, 0, 18446744073709551615, 'inf'::DOUBLE, 'inf'::DOUBLE, 'inf'::FLOAT, '1.0'::DOUBLE),
    (5, -7, 3, -7, 3, -7, 3, -7, 3, 7, 3, 7, 3, 7, 3, 7, 3, '-inf'::DOUBLE, '2.0'::DOUBLE, '-inf'::FLOAT, '1.0'::DOUBLE),
    (6, 7, -3, 7, -3, 7, -3, 7, -3, 7, 255, 7, 65535, 7, 4294967295, 7, 18446744073709551615, 'nan'::DOUBLE, '1.0'::DOUBLE, 'nan'::FLOAT, '1.0'::DOUBLE),
    (7, -7, -3, -7, -3, -7, -3, -7, -3, 255, 255, 65535, 65535, 4294967295, 4294967295, 18446744073709551615, 18446744073709551615, '5e-324'::DOUBLE, '2.0'::DOUBLE, '1.401298464324817e-45'::FLOAT, '1.0'::DOUBLE),
    (8, 127, 127, 32767, 32767, 2147483647, 2147483647, 9223372036854775807, 9223372036854775807, 255, 2, 65535, 2, 4294967295, 2, 18446744073709551615, 2, '2.2250738585072014e-308'::DOUBLE, '10000000000.0'::DOUBLE, '1.1754943508222875e-38'::FLOAT, '1.0'::DOUBLE),
    (9, -127, 1, -32767, 1, -2147483647, 1, -9223372036854775807, 1, 1, 1, 1, 1, 1, 1, 1, 1, '1.7976931348623157e+308'::DOUBLE, '10.0'::DOUBLE, '3.4028234663852886e+38'::FLOAT, '1.0'::DOUBLE),
    (10, 126, 1, 32766, 1, 2147483646, 1, 9223372036854775806, 1, 254, 1, 65534, 1, 4294967294, 1, 18446744073709551614, 1, '9007199254740992.0'::DOUBLE, '1.0'::DOUBLE, '16777216.0'::FLOAT, '1.0'::DOUBLE),
    (11, NULL, 1, NULL, 1, NULL, 1, NULL, 1, NULL, 1, NULL, 1, NULL, 1, NULL, 1, NULL, '1.0'::DOUBLE, NULL, '1.0'::DOUBLE),
    (12, 127, 1, 32767, 1, 2147483647, 1, 9007199254740993, 1, 255, 1, 65535, 1, 4294967295, 1, 18446744073709551615, 1, '0.1'::DOUBLE, '0.2'::DOUBLE, '0.10000000149011612'::FLOAT, '1.0'::DOUBLE);
