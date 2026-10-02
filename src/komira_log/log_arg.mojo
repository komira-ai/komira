# =============================================================================
# komira_log.log_arg — the typed argument model.
# =============================================================================
#
# The facade call shape is `log.info[fmt, module](*args)` where `*args: LogArg`.
# Each arg is a TYPED field (the structured-logging model): the comptime `fmt`
# names the positional slots, and each arg carries its own value + render.
#
# # The structured-field model (P2-stable, documented)
#
# The comptime-fmt + positional typed args ALREADY ARE structured: each `{}`
# in `fmt` is a named, typed field. `log.info["job {} started in {}ms"](job_id,
# elapsed)` is two structured fields (an Int + an Int) with names supplied by
# the surrounding fmt text. This is the NanoLog model and it is what
# P2 binary-encodes (site-id + raw arg bytes).
#
# For EXPLICIT key=value structured fields (the slog/tracing `k=v` form), a
# caller wraps a value in `Field("key", ArgI64(v))` and passes it as a trailing
# arg; the layout renders trailing `Field` args as `key=value` after the
# message. The `Field` wrapper itself conforms to `LogArg`, so the SAME
# variadic `*args` pack carries both positional and key=value fields with no
# second API. P2 carries `Field` as a record with a key-id (interned) + the
# inner arg's raw bytes — identical call sites.
#
# # P1 vs P2 on this trait (the seam)
#
# P1 uses `render(self) -> String` (synchronous format on the calling thread).
# P2 adds `encode_into(self, mut buf: List[UInt8])` + `arg_tag(self) -> UInt8`
# (binary move-encode, NO format on the hot path).
# Defining `arg_tag` + `encode_into` NOW (with P1 bodies) keeps the trait shape
# frozen so P2 swaps only the facade backend, never the arg types or call sites.
#
# Encapsulation: every arg type is plain POD (scalars) or owns a `String`
# (the `ArgStr` / `Field` key). No `UnsafePointer`, no wildcard origin, no
# byte-slab storage of these types — they are passed by the variadic pack and
# consumed in-method. None is stored in a byte-backed slab, so the stale-pointer
# hazard of slab-stored heap owners does not apply.
# =============================================================================

from std.memory import bitcast

from komira_log.engine.log_event_record import ArgBlobWriter


# -----------------------------------------------------------------------------
# Bit-reinterpret helpers for the F64 binary tag (P2 path; defined now so the
# trait body is complete), via the `bitcast` idiom.
# -----------------------------------------------------------------------------


@always_inline
def _f64_bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64, 1](SIMD[DType.float64, 1](v))[0]


# -----------------------------------------------------------------------------
# Arg type tags — the comptime arg signature, materialized into the P2 binary
# record so the type-erased drain decoder knows how to read each arg back.
# (P1 does not use the binary path, but the tags are part of the stable trait.)
# -----------------------------------------------------------------------------

comptime ARG_I64: UInt8 = 1
comptime ARG_F64: UInt8 = 2
comptime ARG_STR: UInt8 = 3
comptime ARG_BOOL: UInt8 = 4
comptime ARG_U64: UInt8 = 5
comptime ARG_FIELD: UInt8 = 6


# -----------------------------------------------------------------------------
# The trait. A single `@parameter for` over a heterogeneous `*args: LogArg` pack
# can call a uniform `render` / `encode_into` / `arg_tag` with NO runtime type
# dispatch — each arm is monomorphized at compile time (the typed-variadic
# pattern).
# -----------------------------------------------------------------------------


trait LogArg(Copyable, Movable):
    def render(self) -> String:
        """P1: synchronous human-readable render of this field's value."""
        ...

    def arg_tag(self) -> UInt8:
        """P2: the binary type tag for the drain decoder."""
        ...

    def encode_into(self, mut buf: List[UInt8]):
        """P2: raw move-encode of this arg's bytes (no format)."""
        ...

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        """Raw move-encode DIRECTLY into a record's inline arg-blob (no
        scratch List alloc on the hot path). Byte-identical wire format to
        `encode_into` — the drain decoder is shared."""
        ...


# -----------------------------------------------------------------------------
# Raw little-endian byte stores for the P2 encode path.
# -----------------------------------------------------------------------------


def _put_u64(mut buf: List[UInt8], v: UInt64):
    for i in range(8):
        buf.append(UInt8((v >> (UInt64(i) * 8)) & 0xFF))


# -----------------------------------------------------------------------------
# The concrete arg wrappers. A caller writes `ArgI64(job_id)` etc.; ergonomic
# implicit-conversion sugar can wrap these (a P1.x nicety), but the explicit
# constructors keep the variadic pack's element trait unambiguous.
# -----------------------------------------------------------------------------


@fieldwise_init
struct ArgI64(LogArg, Copyable, Movable):
    var v: Int64

    def render(self) -> String:
        return String(self.v)

    def arg_tag(self) -> UInt8:
        return ARG_I64

    def encode_into(self, mut buf: List[UInt8]):
        _put_u64(buf, UInt64(Int(self.v)))

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        w.put_u64(UInt64(Int(self.v)))


@fieldwise_init
struct ArgU64(LogArg, Copyable, Movable):
    var v: UInt64

    def render(self) -> String:
        return String(self.v)

    def arg_tag(self) -> UInt8:
        return ARG_U64

    def encode_into(self, mut buf: List[UInt8]):
        _put_u64(buf, self.v)

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        w.put_u64(self.v)


@fieldwise_init
struct ArgF64(LogArg, Copyable, Movable):
    var v: Float64

    def render(self) -> String:
        return String(self.v)

    def arg_tag(self) -> UInt8:
        return ARG_F64

    def encode_into(self, mut buf: List[UInt8]):
        _put_u64(buf, _f64_bits(self.v))

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        w.put_u64(_f64_bits(self.v))


@fieldwise_init
struct ArgBool(LogArg, Copyable, Movable):
    var v: Bool

    def render(self) -> String:
        return String("true") if self.v else String("false")

    def arg_tag(self) -> UInt8:
        return ARG_BOOL

    def encode_into(self, mut buf: List[UInt8]):
        buf.append(UInt8(1) if self.v else UInt8(0))

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        w.append(UInt8(1) if self.v else UInt8(0))


@fieldwise_init
struct ArgStr(LogArg, Copyable, Movable):
    var v: String

    def render(self) -> String:
        return self.v

    def arg_tag(self) -> UInt8:
        return ARG_STR

    def encode_into(self, mut buf: List[UInt8]):
        # length-prefix (u16) + the bytes — the one unavoidable copy, only for
        # string args. Still no formatting; raw byte copy.
        var sb = self.v.as_bytes()
        var n = len(sb)
        buf.append(UInt8(n & 0xFF))
        buf.append(UInt8((n >> 8) & 0xFF))
        for i in range(n):
            buf.append(sb[i])

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        # length-prefix (u16) + bytes. Long strings naturally drive the writer
        # past ARG_INLINE_BYTES → the overflow tail → the arena spill path.
        var sb = self.v.as_bytes()
        var n = len(sb)
        w.append(UInt8(n & 0xFF))
        w.append(UInt8((n >> 8) & 0xFF))
        for i in range(n):
            w.append(sb[i])


# -----------------------------------------------------------------------------
# `Field` — the explicit key=value structured field. Wraps a key (interned in
# P2; a plain `String` in P1) + an inner rendered value string. The inner value
# is pre-rendered at construction so `Field` stays a single concrete type
# (Mojo 1.0.0b1 can't store a `*LogArg`-erased inner without a second trait
# layer; pre-rendering the value keeps the P1 type simple and the call site
# `Field("rows", ArgI64(n))` ergonomic). The layout renders `Field` as
# `key=value`. P2 swaps the pre-rendered value for the raw inner bytes + a
# key-id; the CALL SITE is unchanged.
# -----------------------------------------------------------------------------


struct Field(LogArg, Copyable, Movable):
    var key: String
    var value: String

    def __init__[T: LogArg](out self, var key: String, value: T):
        self.key = key^
        self.value = value.render()

    def render(self) -> String:
        return self.key + "=" + self.value

    def arg_tag(self) -> UInt8:
        return ARG_FIELD

    def encode_into(self, mut buf: List[UInt8]):
        # P2 will length-prefix key + value; P1 stores them as two strings.
        var kb = self.key.as_bytes()
        var nk = len(kb)
        buf.append(UInt8(nk & 0xFF))
        buf.append(UInt8((nk >> 8) & 0xFF))
        for i in range(nk):
            buf.append(kb[i])
        var vb = self.value.as_bytes()
        var nv = len(vb)
        buf.append(UInt8(nv & 0xFF))
        buf.append(UInt8((nv >> 8) & 0xFF))
        for i in range(nv):
            buf.append(vb[i])

    def encode_into_blob[o: Origin[mut=True]](self, mut w: ArgBlobWriter[o]):
        var kb = self.key.as_bytes()
        var nk = len(kb)
        w.append(UInt8(nk & 0xFF))
        w.append(UInt8((nk >> 8) & 0xFF))
        for i in range(nk):
            w.append(kb[i])
        var vb = self.value.as_bytes()
        var nv = len(vb)
        w.append(UInt8(nv & 0xFF))
        w.append(UInt8((nv >> 8) & 0xFF))
        for i in range(nv):
            w.append(vb[i])
