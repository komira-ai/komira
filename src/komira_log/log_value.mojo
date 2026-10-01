# =============================================================================
# komira_log.log_value — the TYPE-ERASED argument value (`LogValue`).
# =============================================================================
#
# THE ONE-LINE REASON THIS EXISTS. `LogArg` is a TRAIT and the emit path takes
# it as a comptime type pack (`*ArgTs: LogArg`, logger.mojo), so the
# argument types are part of the monomorphisation key: every call site with a
# distinct arg-type tuple is a distinct instantiation of the whole emit body.
# `LogValue` is ONE concrete type carrying a RUNTIME tag, so a variadic of it
# (`*args: LogValue`) is a homogeneous variadic — a runtime list, not a type
# pack — and the emit body it feeds is elaborated ONCE for the program.
#
# ⚠ THIS IS NOT A REPLACEMENT FOR `LogArg`, AND THE ENGINE MUST KEEP USING IT.
# The specialised path's whole value is that the arg types are known at compile
# time: the tag table is built by a `comptime for` over the pack, the encode is
# a straight-line store sequence with no branch, and the body is inlined into
# the caller. That is the ~1ns emit the data plane is measured on. `LogValue`
# trades those branches back in — one switch per arg — to buy a shared body.
# The trade is right where sites are many and lines are few (a control plane
# emitting hundreds of lines over minutes) and wrong where sites are few and
# lines are billions (the engine). See logger_erased.mojo for both sides of that
# trade.
#
# # THE WIRE FORMAT IS BYTE-IDENTICAL, DELIBERATELY
#
# `encode_into_blob` writes exactly what the matching `LogArg` conformer writes
# (log_arg.mojo) — the same tags from `log_arg.ARG_*`, the same
# little-endian u64s, the same u16-length-prefixed strings, the same two-string
# layout for a `Field`. So a record emitted through the erased path decodes on
# the SAME drain as one emitted through the specialised path, and there is no
# second decoder. `test_log_erased_emit.mojo` asserts the blobs are equal byte
# for byte rather than merely both being decodable.
#
# # Encapsulation
#
# `LogValue` owns two `String`s. It is passed by the variadic pack and consumed
# in-method; it is NEVER stored in a byte-slab or behind a wildcard origin, so
# the stale-pointer hazard does not apply — the same argument log_arg.mojo makes for
# `ArgStr` / `Field`, which own Strings for the same reason. No `UnsafePointer`
# crosses this module's boundary.
# =============================================================================

from std.memory import bitcast

from komira_log.engine.log_event_record import ArgBlobWriter
from komira_log.log_arg import (
    ARG_I64,
    ARG_U64,
    ARG_F64,
    ARG_STR,
    ARG_BOOL,
    ARG_FIELD,
)


@always_inline
def _f64_bits(v: Float64) -> UInt64:
    """Bit-reinterpret a Float64 for the ARG_F64 payload. Byte-identical to
    `log_arg._f64_bits` (log_arg.mojo) — the drain reads one representation.
    """
    return bitcast[DType.uint64, 1](SIMD[DType.float64, 1](v))[0]


@always_inline
def _f64_of_bits(b: UInt64) -> Float64:
    return bitcast[DType.float64, 1](SIMD[DType.uint64, 1](b))[0]


@fieldwise_init
struct LogValue(Copyable, Movable, Deinitable):
    """One log argument, with its type as RUNTIME data rather than a parameter.

    Construct through the named factories — `LogValue.i64(n)`,
    `LogValue.text(s)`, `LogValue.boolean(b)` — not through the fieldwise
    `__init__` and never through per-type `__init__` OVERLOADS. Overloads were
    deliberately not provided: `Bool`, `Int` and `Float64` convert into one
    another readily enough that an overload set would silently pick a different
    tag than the author meant, and a mis-tagged arg decodes as garbage rather
    than failing to compile.
    """

    # The `log_arg.ARG_*` tag. Runtime here; comptime on the specialised path.
    var tag: UInt8
    # Scalar payload: I64 (two's complement), U64, F64 (bit pattern), or Bool
    # (0/1). Unused (0) for ARG_STR.
    var num: UInt64
    # ARG_STR payload, or the VALUE half of an ARG_FIELD. Empty otherwise.
    var s: String
    # The KEY half of an ARG_FIELD. Empty otherwise.
    var key: String

    # -------------------------------------------------------------------------
    # Factories — one per `LogArg` conformer.
    # -------------------------------------------------------------------------

    @staticmethod
    @always_inline
    def i64(v: Int64) -> LogValue:
        """The `ArgI64` twin."""
        return LogValue(ARG_I64, UInt64(Int(v)), String(""), String(""))

    @staticmethod
    @always_inline
    def u64(v: UInt64) -> LogValue:
        """The `ArgU64` twin."""
        return LogValue(ARG_U64, v, String(""), String(""))

    @staticmethod
    @always_inline
    def f64(v: Float64) -> LogValue:
        """The `ArgF64` twin."""
        return LogValue(ARG_F64, _f64_bits(v), String(""), String(""))

    @staticmethod
    @always_inline
    def boolean(v: Bool) -> LogValue:
        """The `ArgBool` twin."""
        return LogValue(
            ARG_BOOL, UInt64(1) if v else UInt64(0), String(""), String("")
        )

    @staticmethod
    @always_inline
    def text(var v: String) -> LogValue:
        """The `ArgStr` twin."""
        return LogValue(ARG_STR, UInt64(0), v^, String(""))

    @staticmethod
    @always_inline
    def text_static(v: StaticString) -> LogValue:
        """`ArgStr` from a literal, without making the caller write `String(..)`.
        """
        return LogValue(ARG_STR, UInt64(0), String(v), String(""))

    @staticmethod
    def field(var key: String, value: LogValue) -> LogValue:
        """The `Field` twin — an explicit `key=value` structured field.

        The inner value is PRE-RENDERED at construction, exactly as
        `Field.__init__` does (log_arg.mojo), so the encoded layout is
        the same two length-prefixed strings the drain already reads.
        """
        return LogValue(ARG_FIELD, UInt64(0), value.render(), key^)

    # -------------------------------------------------------------------------
    # The `LogArg` surface, re-expressed as a runtime switch. Each arm is
    # copied from the conformer it replaces so the two paths cannot drift.
    # -------------------------------------------------------------------------

    def arg_tag(self) -> UInt8:
        return self.tag

    def render(self) -> String:
        """Human-readable render, matching each conformer's `render()`."""
        if self.tag == ARG_I64:
            return String(Int64(Int(self.num)))
        if self.tag == ARG_U64:
            return String(self.num)
        if self.tag == ARG_F64:
            return String(_f64_of_bits(self.num))
        if self.tag == ARG_BOOL:
            return String("true") if self.num != UInt64(0) else String("false")
        if self.tag == ARG_FIELD:
            return self.key + "=" + self.s
        return self.s

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        """Raw move-encode into a record's inline arg-blob.

        BYTE-IDENTICAL to the corresponding `LogArg.encode_into_blob`; the
        round-trip test asserts equality against the specialised path rather
        than merely asserting the result decodes.
        """
        if self.tag == ARG_STR:
            self._put_str(w, self.s)
            return
        if self.tag == ARG_FIELD:
            self._put_str(w, self.key)
            self._put_str(w, self.s)
            return
        if self.tag == ARG_BOOL:
            w.append(UInt8(1) if self.num != UInt64(0) else UInt8(0))
            return
        # ARG_I64 / ARG_U64 / ARG_F64 all encode as one little-endian u64.
        w.put_u64(self.num)

    @staticmethod
    def _put_str[o: Origin[mut=True]](mut w: ArgBlobWriter[o], s: String):
        """u16 length prefix + raw bytes — `ArgStr.encode_into_blob`'s body
        (log_arg.mojo), shared by the ARG_FIELD arm."""
        var sb = s.as_bytes()
        var n = len(sb)
        w.append(UInt8(n & 0xFF))
        w.append(UInt8((n >> 8) & 0xFF))
        for i in range(n):
            w.append(sb[i])
