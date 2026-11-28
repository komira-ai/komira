# =============================================================================
# echo_udfs -- UdfRefs of the reference runtime's fixtures, for tests
# =============================================================================
#
# The tests of udf_host, pipeline_exec, sdk_exec and so run a UDF without a
# language behind it: on komira-test/echo, the reference runtime of the
# conformance suite (src/tests/helpers/komira_udf_spike_abi, target `:echo`,
# staged as `echo.so`), whose entries are fixed fixtures (`double`,
# `add_strict`, `raise_on_row_3`, ...). `echo_ref` makes the UdfRef a
# producer would record for one of them: its runtime id, a PACKAGE code form
# (no code object), and the spike descriptor version 1
# (komira_udf_spike_descriptor.h: entry, shape bits, the argument and result
# formats), encoded canonically as that runtime's validate requires.
#
# Also here: int64 columns with NULLs, and the reads of one back.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from byte_buffer.heap_region import HeapRegion
from plan_expr.udf_data import UDF_NULL_MANUAL, UDF_NULL_PROPAGATE, UDF_STABILITY_STABLE
from plan_expr.udf_type import UdfType
from plan_ir.udf_ref import (
    CODE_FORM_BUNDLE,
    CODE_FORM_PACKAGE,
    CodeDigest,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_SCALAR,
    UdfCode,
    UdfRef,
    UdfResources,
)

comptime ECHO_RUNTIME = "komira-test/echo"
comptime ECHO_LIBRARY = "./echo.so"
"""Where a test's BUCK `test_data` stages the reference runtime."""


def _varint(mut out: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        out.append(UInt8(x & 0x7F) | 0x80)
        x >>= 7
    out.append(UInt8(x))


def _bytes(mut out: List[UInt8], field: Int, b: List[UInt8]):
    _varint(out, UInt64(field << 3 | 2))
    _varint(out, UInt64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _text(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _spike_field(name: String, format: String) -> List[UInt8]:
    var out = List[UInt8]()
    if name != "":
        _bytes(out, 1, _text(name))
    _bytes(out, 2, _text(format))
    return out^


def echo_descriptor(entry: String, shape: UInt32, arg_formats: List[String], result_format: String) -> List[UInt8]:
    """The spike descriptor of `entry`: fields 1 (entry), 2 (shape bits), 3
    (one per argument, named a<i>) and 4 (the result), in that order."""
    var out = List[UInt8]()
    _bytes(out, 1, _text(entry))
    _varint(out, UInt64(2 << 3))
    _varint(out, UInt64(shape))
    for i in range(len(arg_formats)):
        _bytes(out, 3, _spike_field("a" + String(i), arg_formats[i]))
    _bytes(out, 4, _spike_field("", result_format))
    return out^


def int64_type(name: String, nullable: Bool = True) -> UdfType:
    return UdfType(name, ArrowType.INT64, DType.int64, nullable)


def echo_ref(
    entry: String,
    n_args: Int,
    null_mode: UInt8 = UDF_NULL_MANUAL,
    kind: UInt8 = UDF_REF_KIND_SCALAR,
    max_batch_rows: UInt32 = 0,
    nullable_result: Bool = True,
    runtime: String = ECHO_RUNTIME,
) -> UdfRef:
    """The UdfRef of echo's int64 fixture `entry` over `n_args` int64
    arguments, returning int64."""
    var shape: UInt32 = 4 if kind == UDF_REF_KIND_MAP_BATCHES_COLUMN else 1
    var formats = List[String]()
    var args = List[UdfType]()
    for i in range(n_args):
        formats.append("l")
        args.append(int64_type("a" + String(i)))
    var code = UdfCode(
        runtime, CODE_FORM_PACKAGE, entry, List[CodeDigest](), 1, echo_descriptor(entry, shape, formats, "l")
    )
    return UdfRef(
        kind, code^, args^, Optional(int64_type("out", nullable_result)), UDF_STABILITY_STABLE, null_mode,
        resources=UdfResources(max_batch_rows=max_batch_rows),
    )


def bundle_ref(entry: String, digest: List[UInt8]) -> UdfRef:
    """echo's `double` named as a BUNDLE with one code object of sha256
    `digest`: what admission checks against the code root."""
    var u = echo_ref(entry, 1)
    u.code.form = CODE_FORM_BUNDLE
    u.code.code.append(CodeDigest("bundle", digest.copy()))
    return u^


def int64_column(values: List[Int64], nulls: List[Bool]) raises -> Column[HeapRegion]:
    """An int64 column of `values`, row i NULL where `nulls[i]` (a shorter
    `nulls` leaves the rest valid)."""
    var b = ColumnBuilder[DType.int64].with_capacity(0)
    for i in range(len(values)):
        if i < len(nulls) and nulls[i]:
            b.append_null()
        else:
            b.append(values[i])
    return b^.materialize()


def read_int64(col: Column[HeapRegion]) raises -> List[Optional[Int64]]:
    """The rows of an int64 column, None for NULL."""
    var arr = col.as_primitive[DType.int64]()
    var out = List[Optional[Int64]]()
    for i in range(col.length()):
        if col.is_null_at(i):
            out.append(None)
        else:
            out.append(Optional(arr.get(i)))
    return out^


def render(rows: List[Optional[Int64]]) -> String:
    """`[2, NULL, 6]`: a column's rows for an assertion message."""
    var out = String("[")
    for i in range(len(rows)):
        if i > 0:
            out += ", "
        out += String(rows[i].value()) if rows[i] else String("NULL")
    return out + "]"
