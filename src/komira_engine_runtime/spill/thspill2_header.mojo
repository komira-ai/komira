# =============================================================================
# thspill2_header.mojo — THSPILL2 96-byte fixed header pack/parse.
# =============================================================================
#
# Version 0x02: the schema fingerprint is a UInt64 (FNV-1a 64).
#
# This file owns the on-wire shape of the THSPILL2 fixed header — the first
# 96 bytes of every THSPILL2 chunk.
#
# # Header plus an opaque body
#
# A richer design lists encoder fields for the rich body shape
# (cols_section + data_region + aggr_region + var_offsets + var_storage)
# which only becomes meaningful once the RowBlock primitive lands in
# P-1.D/P-1.E. P-1.B ships the LOAD-BEARING substrate: the 96-byte fixed
# header + a generic byte-body. Real `Spillable` conformers (RowBlock
# proper) layer the body shape on top in subsequent slots.
#
# This shape is COMPATIBLE with the §10.7 rich body: the header reserves
# 48 bytes for v0.6+ extension; the body is OPAQUE BYTES from the codec's
# perspective. P-1.D's HashAggUntyped spill writes its RowBlock partition
# bytes as the body; P-1.B's decoder hands the body bytes back to the
# operator's `from_bytes` constructor.
#
# # 96-byte layout (v0.6; little-endian throughout)
#
#   bytes  0..  3 : magic "THS\x02"             (UInt8 ×4)
#   bytes  4..  7 : version                     (UInt32; v0.6 ships 0x02)
#   bytes  8.. 15 : body_length                 (UInt64; bytes after header)
#   bytes 16.. 23 : row_count                   (UInt64)
#   bytes 24.. 31 : schema_fingerprint          (UInt64; WIDENED v0.6 —
#                                                FNV-1a-64 per §10.10.3)
#   bytes 32.. 39 : uncompressed_body_length    (UInt64; for flag bit0;
#                                                equal to body_length when
#                                                bit0=0)
#   bytes 40.. 43 : flags                       (UInt32; bit0=compressed-lz4,
#                                                bit1=sort-key-encoded; rest
#                                                reserved=0)
#   bytes 44.. 47 : reserved_b                  (UInt32; zero on write,
#                                                ignored on read for forward
#                                                compat)
#   bytes 48.. 95 : reserved_extension          (48 bytes; zero on write,
#                                                ignored on read for v0.6+
#                                                CRC32 / producer_id /
#                                                run_id metadata)
#
# Total: 96 bytes (= 1.5 cache lines on x86_64 / arm64). 96 was picked to
# keep 16-byte alignment for the body
# (96 % 16 == 0) so RowBlock's 16-byte payload alignment is preserved when
# the body starts at offset 96. All UInt64 fields land on 8-byte
# boundaries in the v0.6 layout (alignment preserved across the v0.5 →
# v0.6 re-pack).
#
# # Magic bytes + version
#
# "THS\x02" — the magic identifies the **era** (v0.4 internal-format).
# The `version` UInt32 at bytes [4..7] is what readers dispatch on for
# revision changes within the era. v0.5 fixtures (written with
# version=0x01) raise a loud "unknown version" error against the v0.6
# reader.
#
# # Encapsulation
#
# Pure data + helpers. No fields hold pointers. No FFI. The functions
# operate over `Span[UInt8, origin]` or take/return value types.
#
# # Why a separate file (not inlined into `thspill2.mojo`)
#
# Header pack/parse is a value-type concern testable in isolation. Tests
# can exercise the header round-trip without dragging in the codec /
# SpillStorage stack. Subsequent format-version bumps land here.
# =============================================================================



# =============================================================================
# Constants
# =============================================================================

comptime THSPILL2_HEADER_SIZE: Int = 96

# Version: v0.6 ships 0x02. v0.5 fixtures (version=0x01) raise on parse.
comptime THSPILL2_VERSION_V2: UInt32 = 2

# Backward-compat name retained for any in-tree caller; equals V2 today
# (v0.6 reader accepts only V2). Prior P-1.B tests referenced
# `THSPILL2_VERSION_V1` — those tests are updated to V2 in P-1.D.1.a.
comptime THSPILL2_VERSION_V1: UInt32 = THSPILL2_VERSION_V2

# Magic byte sequence "THS\x02".
comptime THSPILL2_MAGIC_0: UInt8 = 0x54  # 'T'
comptime THSPILL2_MAGIC_1: UInt8 = 0x48  # 'H'
comptime THSPILL2_MAGIC_2: UInt8 = 0x53  # 'S'
comptime THSPILL2_MAGIC_3: UInt8 = 0x02  # version-2 era

# Flag bits.
comptime THSPILL2_FLAG_COMPRESSED_LZ4: UInt32 = 1
comptime THSPILL2_FLAG_SORT_KEY_ENCODED: UInt32 = 2
# Bits 2..31 reserved. Mask of bits known to the v0.6 reader:
comptime THSPILL2_FLAG_KNOWN_MASK: UInt32 = (
    THSPILL2_FLAG_COMPRESSED_LZ4 | THSPILL2_FLAG_SORT_KEY_ENCODED
)


# =============================================================================
# THSpill2Header — parsed/in-construction value type.
# =============================================================================


struct THSpill2Header(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Parsed THSPILL2 fixed header. Value-shaped POD — no fields hold
    pointers. Carried by the encoder during construction and produced by
    the decoder during parse.

    Fields:
        version:                   Format-version (v0.6 ships 2).
        body_length:               Bytes immediately following the 96-byte
                                   header (the operator's payload).
        row_count:                 Logical row count in the chunk.
        schema_fingerprint:        Caller's schema identity (UInt64; FNV-1a-
                                   64 over `entry_stride_le_8B ||
                                   agg_tag_list_bytes`); used at restore
                                   time for fingerprint-mismatch detection.
        uncompressed_body_length:  For the compressed flag; equal to
                                   body_length when uncompressed.
        flags:                     Bitfield (see THSPILL2_FLAG_* constants).
    """

    var version: UInt32
    var body_length: UInt64
    var row_count: UInt64
    var schema_fingerprint: UInt64
    var uncompressed_body_length: UInt64
    var flags: UInt32

    def __init__(
        out self,
        version: UInt32,
        body_length: UInt64,
        row_count: UInt64,
        schema_fingerprint: UInt64,
        flags: UInt32,
        uncompressed_body_length: UInt64,
    ):
        """Field-wise ctor. Encoders construct directly; decoders return
        Self from `parse_header`.

        Parameter ORDER (kept the same as P-1.B for call-site stability):
        version, body_length, row_count, schema_fingerprint, flags,
        uncompressed_body_length. The struct's FIELD order is re-packed
        to match the v0.6 on-wire layout, but the keyword-arg API stays
        identical so call sites do not churn.
        """
        self.version = version
        self.body_length = body_length
        self.row_count = row_count
        self.schema_fingerprint = schema_fingerprint
        self.flags = flags
        self.uncompressed_body_length = uncompressed_body_length

    @staticmethod
    def for_uncompressed(
        body_length: UInt64,
        row_count: UInt64,
        schema_fingerprint: UInt64,
    ) -> Self:
        """Convenience ctor for the most common shape: uncompressed,
        no sort-key-encoded variant. v0.6 ships this shape by default.
        """
        return Self(
            version=THSPILL2_VERSION_V2,
            body_length=body_length,
            row_count=row_count,
            schema_fingerprint=schema_fingerprint,
            flags=UInt32(0),
            uncompressed_body_length=body_length,
        )


# =============================================================================
# pack_header — write the 96 bytes into a destination span.
# =============================================================================


def pack_header[
    origin: Origin[mut=True], //,
](header: THSpill2Header, dst: Span[Byte, origin]) raises:
    """Serialize `header` into the first 96 bytes of `dst` (little-endian).

    `len(dst)` MUST be `>= THSPILL2_HEADER_SIZE`; raises otherwise.

    The reserved bytes (44..47 + 48..95) are zeroed on write so the
    on-disk image is reproducible (helpful for byte-identity testing).

    Args:
        header: Header value to serialize.
        dst:    Destination byte span. Header written at offsets 0..95.

    Raises:
        On `dst.len() < THSPILL2_HEADER_SIZE`.
    """
    var dst_len = len(dst)
    if dst_len < THSPILL2_HEADER_SIZE:
        raise Error(
            "pack_header: destination too small (need "
            + String(THSPILL2_HEADER_SIZE)
            + " bytes, got "
            + String(dst_len)
            + ")"
        )

    # SAFETY: `dst` is a tracked Span; offsets 0..95 are bounds-checked
    # above. All writes are scalar little-endian stores via unaligned
    # bitcast — the Mojo `.bitcast[T]().store[alignment=1]` idiom matches
    # SAB's `write_*_le_at`. We use the base pointer directly here
    # (rather than dispatching through SAB) because pack_header is a
    # pure value-on-byte-span operation and does not need an owning
    # buffer wrapper.
    var base = dst.unsafe_ptr()

    # bytes 0..3 — magic
    (base + 0)[] = THSPILL2_MAGIC_0
    (base + 1)[] = THSPILL2_MAGIC_1
    (base + 2)[] = THSPILL2_MAGIC_2
    (base + 3)[] = THSPILL2_MAGIC_3

    # bytes 4..7 — version (UInt32 LE)
    (base + 4).bitcast[UInt32]().store[alignment=1](header.version)

    # bytes 8..15 — body_length (UInt64 LE)
    (base + 8).bitcast[UInt64]().store[alignment=1](header.body_length)

    # bytes 16..23 — row_count (UInt64 LE)
    (base + 16).bitcast[UInt64]().store[alignment=1](header.row_count)

    # bytes 24..31 — schema_fingerprint (UInt64 LE; WIDENED v0.6)
    (base + 24).bitcast[UInt64]().store[alignment=1](
        header.schema_fingerprint
    )

    # bytes 32..39 — uncompressed_body_length (UInt64 LE)
    (base + 32).bitcast[UInt64]().store[alignment=1](
        header.uncompressed_body_length
    )

    # bytes 40..43 — flags (UInt32 LE)
    (base + 40).bitcast[UInt32]().store[alignment=1](header.flags)

    # bytes 44..47 — reserved_b (UInt32 LE; zero on write)
    (base + 44).bitcast[UInt32]().store[alignment=1](UInt32(0))

    # bytes 48..95 — reserved extension (48 bytes; zero)
    var i = 48
    while i < THSPILL2_HEADER_SIZE:
        (base + i)[] = UInt8(0)
        i += 1


# =============================================================================
# parse_header — validate magic / version / shape; return header value.
# =============================================================================


def parse_header(src: Span[UInt8, _]) raises -> THSpill2Header:
    """Read the 96-byte header from `src`. Validates magic + version +
    overall length consistency.

    Raises:
        * "bad magic" — `src` does not begin with "THS\\x02".
        * "unknown version" — `header.version` is not `THSPILL2_VERSION_V2`.
          v0.5 fixtures (version=0x01) raise here so stale fixtures
          surface a clear error rather than silently mis-parse against
          the v0.6 layout.
        * "buffer shorter than header" — `src.len() < 96`.

    Note: the body_length / row_count consistency check (i.e. that the
    caller's surrounding buffer is `>= 96 + body_length`) is the
    DECODER's responsibility, NOT this function's — `parse_header`
    operates on the header bytes alone and reports the declared
    body_length without verifying it against the surrounding buffer's
    length. The decoder cross-checks at its boundary.

    Args:
        src: Source byte span. First `THSPILL2_HEADER_SIZE` bytes read.

    Returns:
        Parsed `THSpill2Header`.
    """
    var src_len = len(src)
    if src_len < THSPILL2_HEADER_SIZE:
        raise Error(
            "parse_header: buffer shorter than header (need "
            + String(THSPILL2_HEADER_SIZE)
            + " bytes, got "
            + String(src_len)
            + ")"
        )

    # SAFETY: bounds confirmed above. All reads are little-endian
    # unaligned scalar loads via bitcast — same shape as SAB.read_*_le_at.
    var base = src.unsafe_ptr()

    # bytes 0..3 — magic
    var m0 = (base + 0)[]
    var m1 = (base + 1)[]
    var m2 = (base + 2)[]
    var m3 = (base + 3)[]
    if (
        m0 != THSPILL2_MAGIC_0
        or m1 != THSPILL2_MAGIC_1
        or m2 != THSPILL2_MAGIC_2
        or m3 != THSPILL2_MAGIC_3
    ):
        raise Error(
            "parse_header: bad magic — expected 'THS\\x02' got bytes ["
            + String(Int(m0))
            + ", "
            + String(Int(m1))
            + ", "
            + String(Int(m2))
            + ", "
            + String(Int(m3))
            + "]"
        )

    # bytes 4..7 — version
    var version = (base + 4).bitcast[UInt32]().load[alignment=1]()
    if version != THSPILL2_VERSION_V2:
        raise Error(
            "parse_header: unknown version "
            + String(Int(version))
            + " (v0.6 reader accepts only version "
            + String(Int(THSPILL2_VERSION_V2))
            + ")"
        )

    var body_length = (base + 8).bitcast[UInt64]().load[alignment=1]()
    var row_count = (base + 16).bitcast[UInt64]().load[alignment=1]()
    var schema_fingerprint = (
        (base + 24).bitcast[UInt64]().load[alignment=1]()
    )
    var uncompressed_body_length = (
        (base + 32).bitcast[UInt64]().load[alignment=1]()
    )
    var flags = (base + 40).bitcast[UInt32]().load[alignment=1]()
    # bytes 44..47 + 48..95 — reserved; intentionally NOT read. Forward
    # compat: future writers may populate; this v0.6 reader ignores.

    return THSpill2Header(
        version=version,
        body_length=body_length,
        row_count=row_count,
        schema_fingerprint=schema_fingerprint,
        flags=flags,
        uncompressed_body_length=uncompressed_body_length,
    )
