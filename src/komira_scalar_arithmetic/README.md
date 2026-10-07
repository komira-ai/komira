# komira_scalar_arithmetic

Scalar decimal and integer arithmetic. A decimal is an unscaled integer plus a
scale: `I128` (`SIMD[DType.int128, 1]`) for Decimal128 (at most 38 digits) and
`I256` for Decimal256 (at most 76 digits). `decimal_arith` and
`decimal256_arith` add, subtract, multiply and divide them, computing in a
wider intermediate and raising on overflow; division rounds half away from
zero, and the `*_result_ps` functions give the precision and scale of a
result. `decimal_cast` converts between decimals and integers, floats and
strings, `decimal_compare` compares two decimals at different scales, and
`int_overflow` holds the overflow predicates and the checked `+ - *` for
fixed-width integers, which raise `Out of Range Error: Overflow in ...`
instead of wrapping.

## Examples

Add and divide Decimal128 values at different scales:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_scalar_arithmetic.decimal_arith import I128, decimal_add_i128, decimal_add_result_ps, decimal_div_i128

# 123.45 (DECIMAL(5,2)) + 6.789 (DECIMAL(4,3))
var ps = decimal_add_result_ps(5, 2, 4, 3)
assert_equal(ps[0], 7)
assert_equal(ps[1], 3)
assert_equal(decimal_add_i128(I128(12345), 2, I128(6789), 3, 3), I128(130239))

# 1.00 / 3.00 at scale 6 is 0.333333; 2.00 / 3.00 rounds half up to 0.666667
assert_equal(decimal_div_i128(I128(100), 2, I128(300), 2, 6), I128(333333))
assert_equal(decimal_div_i128(I128(200), 2, I128(300), 2, 6), I128(666667))
```

Parse, format and compare decimals:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import decimal_to_string, string_to_decimal_i128
from komira_scalar_arithmetic.decimal_compare import DEC_CMP_EQ, DEC_CMP_LT, decimal_cmp_i128

var v = string_to_decimal_i128(" -1.255 ", 10, 2)
assert_equal(v, I128(-126))
assert_equal(decimal_to_string(v, 2), "-1.26")
assert_equal(decimal_to_string(I128(5), 3), "0.005")
# 1.5 (scale 1) equals 1.50 (scale 2); 1.5 is less than 1.51
assert_true(decimal_cmp_i128(I128(15), 1, I128(150), 2, DEC_CMP_EQ))
assert_true(decimal_cmp_i128(I128(15), 1, I128(151), 2, DEC_CMP_LT))
```

Integer `+` raises instead of wrapping:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_scalar_arithmetic.int_overflow import add_overflows, checked_add, is_int_overflow_error

assert_true(add_overflows[DType.int64](Int64.MAX, Int64(1)))
assert_false(add_overflows[DType.int64](Int64(2), Int64(3)))
assert_equal(checked_add[DType.int64](Int64(2), Int64(3)), Int64(5))
var message = String()
try:
    _ = checked_add[DType.int64](Int64.MAX, Int64(1))
except e:
    message = String(e)
assert_equal(message, "Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!")
assert_true(is_int_overflow_error(message))
```

Decimal256 multiplication raises when the product leaves 76 digits:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_scalar_arithmetic.decimal256_arith import I256, decimal256_mul_i256, max_dec256_i256

assert_equal(decimal256_mul_i256(I256(-25), I256(4)), I256(-100))
var refused = False
try:
    _ = decimal256_mul_i256(max_dec256_i256(), I256(2))
except:
    refused = True
assert_true(refused)
```
