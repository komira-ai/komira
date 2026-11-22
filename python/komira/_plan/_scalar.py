"""Constants: a `Lit` value as a `WireScalar`, and the field the engine types
that scalar with.

Each Python type has one scalar shape, the one the engine's own factory for
that kind builds (src/plan_expr/scalar_value.mojo):

    None               a NULL of type int64 (float64 where a CASE promotes it)
    bool               bool
    int                int64; uint64 from 2**63 up to 2**64 - 1
    float              float64
    str                a string
    bytes              binary (UTF-8 bytes only: the wire carries them as text)
    decimal.Decimal    decimal128, its precision the integer digits (at least
                       one) plus the scale
    datetime.date      date32, days since 1970-01-01
    datetime.datetime  a timestamp in microseconds since 1970-01-01 (naive only)
    datetime.time      a time of day in microseconds (naive only)
    datetime.timedelta an interval of days and nanoseconds

Every scalar carries `kind` and `time_unit` (microseconds), the two enums the
reader refuses at zero.
"""

from __future__ import annotations

import datetime
import decimal

from komira._errors import UnsupportedOperation

from ._wire import arrow_id, field, pb, vocab

__all__ = ["literal_field", "scalar"]

_INT64_MIN = -(2**63)
_UINT64_END = 2**64
_DEC128_MAX_PRECISION = 38
_EPOCH_DATE = datetime.date(1970, 1, 1)
_EPOCH = datetime.datetime(1970, 1, 1)
_MICRO = datetime.timedelta(microseconds=1)


def _refuse(what: str, why: str) -> UnsupportedOperation:
    return UnsupportedOperation(f"a literal {what} cannot be encoded: {why}")


def _int(s: pb.WireScalar, value: int, as_float: bool) -> None:
    if value < _INT64_MIN or value >= _UINT64_END:
        raise _refuse(
            f"integer {value}",
            "it is outside int64 and uint64; pass it as a decimal.Decimal or a float",
        )
    if as_float:
        s.dtype_code = vocab._DT_FLOAT64
        s.float_val = float(value)
    elif value < -_INT64_MIN:
        s.dtype_code = vocab._DT_INT64
        s.int_val = value
    else:
        # uint64 travels as its two's-complement bit pattern in int_val.
        s.dtype_code = vocab._DT_UINT64
        s.int_val = value - _UINT64_END


def _decimal(s: pb.WireScalar, value: decimal.Decimal) -> None:
    if not value.is_finite():
        raise _refuse(f"decimal {value}", "only a finite decimal has a decimal128 value")
    sign, digits, exponent = value.as_tuple()
    unscaled = int("".join(str(d) for d in digits))
    scale = max(0, -exponent)
    # The integer digits (at least one) plus the scale, counted before the
    # value is built, so a huge exponent is refused without expanding it.
    integer_digits = len(digits) + exponent if exponent >= 0 else len(str(unscaled // 10**scale))
    precision = (integer_digits if unscaled else 1) + scale
    if precision > _DEC128_MAX_PRECISION:
        raise _refuse(
            f"decimal {value}",
            f"it needs a precision of {precision}, and decimal128 holds at most 38 digits",
        )
    if exponent > 0:
        unscaled *= 10**exponent
    if sign:
        unscaled = -unscaled
    low = unscaled & (_UINT64_END - 1)
    s.kind = vocab.SCALAR_KIND_DECIMAL128
    s.dec128_high = unscaled >> 64
    # The low word is a signed int64 on the wire: its bit pattern.
    s.dec128_low = low - _UINT64_END if low >= -_INT64_MIN else low
    s.dec128_precision = precision
    s.dec128_scale = scale


def _naive(value, what: str) -> None:
    if value.tzinfo is not None:
        raise _refuse(
            f"{what} with a time zone ({value.tzinfo})",
            f"the wire's {what} literal has no zone; pass a naive {what}",
        )


def scalar(value: object, as_float: bool = False) -> pb.WireScalar:
    """The `WireScalar` of a `Lit` value. With `as_float`, an int becomes a
    float64 and None a float64 NULL: the literals of a CASE whose type is
    float64."""
    s = pb.WireScalar(kind=vocab.SCALAR_KIND_DTYPE, time_unit=vocab.SCALAR_TIME_UNIT_MICRO)
    if value is None:
        s.null_dtype_code = vocab._DT_FLOAT64 if as_float else vocab._DT_INT64
    elif isinstance(value, bool):
        s.dtype_code = vocab._DT_BOOL
        s.bool_val = value
    elif isinstance(value, int):
        _int(s, value, as_float)
    elif isinstance(value, float):
        s.dtype_code = vocab._DT_FLOAT64
        s.float_val = value
    elif isinstance(value, str):
        s.kind = vocab.SCALAR_KIND_STRING
        s.string_val = value
    elif isinstance(value, bytes):
        try:
            text = value.decode("utf-8")
        except UnicodeDecodeError:
            raise _refuse(
                f"bytes value {value!r}",
                "the wire carries binary literals as UTF-8 text, and these bytes are not UTF-8",
            ) from None
        s.kind = vocab.SCALAR_KIND_BINARY
        s.string_val = text
    elif isinstance(value, decimal.Decimal):
        _decimal(s, value)
    elif isinstance(value, datetime.datetime):
        _naive(value, "datetime")
        s.kind = vocab.SCALAR_KIND_TIMESTAMP
        s.ts_micros = (value - _EPOCH) // _MICRO
    elif isinstance(value, datetime.date):
        s.kind = vocab.SCALAR_KIND_DATE32
        s.date32_val = (value - _EPOCH_DATE).days
    elif isinstance(value, datetime.time):
        _naive(value, "time")
        s.kind = vocab.SCALAR_KIND_TIME
        s.int_val = (
            (value.hour * 60 + value.minute) * 60 + value.second
        ) * 1_000_000 + value.microsecond
    else:
        # `Lit` admits nothing else: a timedelta is the last of its types.
        s.kind = vocab.SCALAR_KIND_INTERVAL
        s.iv_days = value.days
        s.iv_nanos = (value.seconds * 1_000_000 + value.microseconds) * 1000
    return s


def literal_field(s: pb.WireScalar) -> pb.WireField:
    """The field the engine types a literal with (`walk_expr_field`,
    src/plan_expr/expr_walk.mojo): named `literal`, never nullable; a decimal
    keeps its precision (never 0 here) and scale, a string, date and timestamp have their own
    types, and every other kind is typed by its DType (a NULL by the type it
    stands for), which time, interval and binary do not have, so they are typed
    `null` as the engine types them."""
    if s.kind == vocab.SCALAR_KIND_DECIMAL128:
        f = field("literal", arrow_id("decimal128"), False)
        f.decimal_precision = s.dec128_precision
        f.decimal_scale = s.dec128_scale
        return f
    if s.kind == vocab.SCALAR_KIND_STRING:
        return field("literal", arrow_id("string"), False)
    if s.kind == vocab.SCALAR_KIND_DATE32:
        return field("literal", arrow_id("date32"), False)
    if s.kind == vocab.SCALAR_KIND_TIMESTAMP:
        return field("literal", arrow_id("timestamp_us"), False)
    code = s.dtype_code
    if s.kind == vocab.SCALAR_KIND_DTYPE and code == vocab._DT_INVALID:
        code = s.null_dtype_code
    if s.kind != vocab.SCALAR_KIND_DTYPE or code == vocab._DT_INVALID:
        return field("literal", arrow_id("null"), False)
    return field("literal", arrow_id(vocab.DTypeCode.Name(code).removeprefix("_DT_")), False)
