# =============================================================================
# thsplc_header.mojo: the THSPLC 96-byte fixed header.
# =============================================================================
#
# # 96-byte layout (little-endian throughout)
#
#   bytes  0..  7 : magic "THSPLC\x01\x00"     (UInt8 ×8)
#   bytes  8.. 11 : version                     (UInt32; 0x01)
#   bytes 12.. 15 : n_cols                       (UInt32; number of columns)
#   bytes 16.. 23 : body_length                  (UInt64; bytes after header,
#                                                 EXCLUDING the trailing magic)
#   bytes 24.. 31 : row_count                    (UInt64)
#   bytes 32.. 39 : schema_fingerprint           (UInt64; FNV-1a-64)
#   bytes 40.. 43 : flags                        (UInt32; bit0=compressed,
#                                                 bit1=has_selection_vector;
#                                                 rest reserved=0)
#   bytes 44.. 47 : descriptors_byte_len         (UInt32; size of the per-column
#                                                 descriptor section that
#                                                 immediately follows the header)
#   bytes 48.. 95 : reserved_extension           (48 bytes; zero on write,
#                                                 ignored on read)
#
# Total: 96 bytes (= 1.5 cache lines). All UInt64 fields land on 8-byte
# boundaries; the body (descriptor section) starts at offset 96 (96 % 64 ==
# 32, but 96 % 8 == 0 so descriptor Int32/Int64 reads are aligned).
#
# # Magic bytes + version
#
# The first 6 bytes spell "THSPLC"; byte 6 = 0x01 (era); byte 7 = 0x00
# (padding). The 8-byte trailing magic repeats them. The `version` UInt32 at
# [8..11] is what readers dispatch on for revision changes within the era.
#
# # Encapsulation
#
# Pure data + helpers. No fields hold pointers. No FFI. The functions operate
# over `Span[UInt8, origin]` or take/return value types.
# =============================================================================


# =============================================================================
# Constants
# =============================================================================

comptime THSPLC_HEADER_SIZE: Int = 96

# Trailing magic length (the 8 magic bytes, appended after the body).
comptime THSPLC_TRAILER_SIZE: Int = 8

# The only version this reader accepts.
comptime THSPLC_VERSION_V1: UInt32 = 1

# Magic byte sequence (8 bytes).
comptime THSPLC_MAGIC_0: UInt8 = 0x54  # 'T'
comptime THSPLC_MAGIC_1: UInt8 = 0x48  # 'H'
comptime THSPLC_MAGIC_2: UInt8 = 0x53  # 'S'
comptime THSPLC_MAGIC_3: UInt8 = 0x50  # 'P'
comptime THSPLC_MAGIC_4: UInt8 = 0x4C  # 'L'
comptime THSPLC_MAGIC_5: UInt8 = 0x43  # 'C'
comptime THSPLC_MAGIC_6: UInt8 = 0x01  # version-1 era
comptime THSPLC_MAGIC_7: UInt8 = 0x00  # padding

# Flag bits.
comptime THSPLC_FLAG_COMPRESSED: UInt32 = 1
comptime THSPLC_FLAG_HAS_SELECTION_VECTOR: UInt32 = 2
comptime THSPLC_FLAG_KNOWN_MASK: UInt32 = (
    THSPLC_FLAG_COMPRESSED | THSPLC_FLAG_HAS_SELECTION_VECTOR
)


# =============================================================================
# THSPLCHeader — parsed/in-construction value type.
# =============================================================================


struct THSPLCHeader(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Parsed THSPLC fixed header. Value-shaped POD — no fields hold
    pointers. Carried by the encoder during construction and produced by the
    decoder during parse.

    Fields:
        version:            Format version (1).
        n_cols:             Number of columns in the batch.
        body_length:        Bytes after the 96-byte header (descriptor section
                            + per-column buffers), EXCLUDING the trailing
                            8-byte magic.
        row_count:          Logical row count in the batch.
        schema_fingerprint: Caller's schema identity (UInt64; FNV-1a-64).
        flags:              Bitfield (see THSPLC_FLAG_* constants).
        descriptors_byte_len: Size of the per-column descriptor section that
                            immediately follows the header.
    """

    var version: UInt32
    var n_cols: UInt32
    var body_length: UInt64
    var row_count: UInt64
    var schema_fingerprint: UInt64
    var flags: UInt32
    var descriptors_byte_len: UInt32

    def __init__(
        out self,
        version: UInt32,
        n_cols: UInt32,
        body_length: UInt64,
        row_count: UInt64,
        schema_fingerprint: UInt64,
        flags: UInt32,
        descriptors_byte_len: UInt32,
    ):
        """Field-wise ctor. Encoders construct directly; decoders return Self
        from `parse_thsplc_header`."""
        self.version = version
        self.n_cols = n_cols
        self.body_length = body_length
        self.row_count = row_count
        self.schema_fingerprint = schema_fingerprint
        self.flags = flags
        self.descriptors_byte_len = descriptors_byte_len

    @staticmethod
    def for_uncompressed(
        n_cols: UInt32,
        body_length: UInt64,
        row_count: UInt64,
        schema_fingerprint: UInt64,
        descriptors_byte_len: UInt32,
    ) -> Self:
        """Convenience ctor for the common shape: uncompressed, no selection
        vector."""
        return Self(
            version=THSPLC_VERSION_V1,
            n_cols=n_cols,
            body_length=body_length,
            row_count=row_count,
            schema_fingerprint=schema_fingerprint,
            flags=UInt32(0),
            descriptors_byte_len=descriptors_byte_len,
        )


# =============================================================================
# pack_thsplc_header — write the 96 bytes into a destination span.
# =============================================================================


def pack_thsplc_header[
    origin: Origin[mut=True], //,
](header: THSPLCHeader, dst: Span[Byte, origin]) raises:
    """Serialize `header` into the first 96 bytes of `dst` (little-endian).

    `len(dst)` MUST be `>= THSPLC_HEADER_SIZE`; raises otherwise. The reserved
    bytes (48..95) are zeroed on write so the on-disk image is reproducible.
    """
    var dst_len = len(dst)
    if dst_len < THSPLC_HEADER_SIZE:
        raise Error(
            "pack_thsplc_header: destination too small (need "
            + String(THSPLC_HEADER_SIZE)
            + " bytes, got "
            + String(dst_len)
            + ")"
        )

    # SAFETY: `dst` is a tracked Span; offsets 0..95 are bounds-checked above.
    # All writes are scalar little-endian stores via unaligned bitcast. `dst`
    # is held alive by the caller (the OAB owning the bytes) for the duration
    # of this call.
    var base = dst.unsafe_ptr()

    # bytes 0..7 — magic
    (base + 0)[] = THSPLC_MAGIC_0
    (base + 1)[] = THSPLC_MAGIC_1
    (base + 2)[] = THSPLC_MAGIC_2
    (base + 3)[] = THSPLC_MAGIC_3
    (base + 4)[] = THSPLC_MAGIC_4
    (base + 5)[] = THSPLC_MAGIC_5
    (base + 6)[] = THSPLC_MAGIC_6
    (base + 7)[] = THSPLC_MAGIC_7

    # bytes 8..11 — version (UInt32 LE)
    (base + 8).bitcast[UInt32]().store[alignment=1](header.version)

    # bytes 12..15 — n_cols (UInt32 LE)
    (base + 12).bitcast[UInt32]().store[alignment=1](header.n_cols)

    # bytes 16..23 — body_length (UInt64 LE)
    (base + 16).bitcast[UInt64]().store[alignment=1](header.body_length)

    # bytes 24..31 — row_count (UInt64 LE)
    (base + 24).bitcast[UInt64]().store[alignment=1](header.row_count)

    # bytes 32..39 — schema_fingerprint (UInt64 LE)
    (base + 32).bitcast[UInt64]().store[alignment=1](
        header.schema_fingerprint
    )

    # bytes 40..43 — flags (UInt32 LE)
    (base + 40).bitcast[UInt32]().store[alignment=1](header.flags)

    # bytes 44..47 — descriptors_byte_len (UInt32 LE)
    (base + 44).bitcast[UInt32]().store[alignment=1](
        header.descriptors_byte_len
    )

    # bytes 48..95 — reserved extension (48 bytes; zero)
    var i = 48
    while i < THSPLC_HEADER_SIZE:
        (base + i)[] = UInt8(0)
        i += 1


# =============================================================================
# parse_thsplc_header — validate magic / version; return header value.
# =============================================================================


def parse_thsplc_header(src: Span[UInt8, _]) raises -> THSPLCHeader:
    """Read the 96-byte header from `src`. Validates magic + version.

    Raises:
        * "bad magic" — `src` does not begin with the 8 THSPLC magic bytes.
        * "unknown version" — `header.version` is not `THSPLC_VERSION_V1`.
        * "buffer shorter than header" — `src.len() < 96`.

    The body_length / row_count consistency check (that
    the surrounding buffer is `>= 96 + body_length + 8`) is the DECODER's
    responsibility, not this function's.
    """
    var src_len = len(src)
    if src_len < THSPLC_HEADER_SIZE:
        raise Error(
            "parse_thsplc_header: buffer shorter than header (need "
            + String(THSPLC_HEADER_SIZE)
            + " bytes, got "
            + String(src_len)
            + ")"
        )

    # SAFETY: bounds confirmed above. All reads are little-endian unaligned
    # scalar loads via bitcast.
    var base = src.unsafe_ptr()

    # bytes 0..7 — magic
    if (
        (base + 0)[] != THSPLC_MAGIC_0
        or (base + 1)[] != THSPLC_MAGIC_1
        or (base + 2)[] != THSPLC_MAGIC_2
        or (base + 3)[] != THSPLC_MAGIC_3
        or (base + 4)[] != THSPLC_MAGIC_4
        or (base + 5)[] != THSPLC_MAGIC_5
        or (base + 6)[] != THSPLC_MAGIC_6
        or (base + 7)[] != THSPLC_MAGIC_7
    ):
        raise Error(
            "parse_thsplc_header: bad magic — expected"
            " 'THSPLC\\x01\\x00'"
        )

    # bytes 8..11 — version
    var version = (base + 8).bitcast[UInt32]().load[alignment=1]()
    if version != THSPLC_VERSION_V1:
        raise Error(
            "parse_thsplc_header: unknown version "
            + String(Int(version))
            + " (this reader accepts only version "
            + String(Int(THSPLC_VERSION_V1))
            + ")"
        )

    var n_cols = (base + 12).bitcast[UInt32]().load[alignment=1]()
    var body_length = (base + 16).bitcast[UInt64]().load[alignment=1]()
    var row_count = (base + 24).bitcast[UInt64]().load[alignment=1]()
    var schema_fingerprint = (
        (base + 32).bitcast[UInt64]().load[alignment=1]()
    )
    var flags = (base + 40).bitcast[UInt32]().load[alignment=1]()
    var descriptors_byte_len = (
        (base + 44).bitcast[UInt32]().load[alignment=1]()
    )

    return THSPLCHeader(
        version=version,
        n_cols=n_cols,
        body_length=body_length,
        row_count=row_count,
        schema_fingerprint=schema_fingerprint,
        flags=flags,
        descriptors_byte_len=descriptors_byte_len,
    )
