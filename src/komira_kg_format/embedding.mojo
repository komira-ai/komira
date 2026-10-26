# =============================================================================
# embedding -- the packed-embedding cell format.
# =============================================================================
#
# An embedding vector is stored as ONE string cell whose bytes are the vector's
# little-endian f32 components:
#
#   bytes = LE-f32(v[0]) ++ LE-f32(v[1]) ++ ... ++ LE-f32(v[dim-1])
#   len(bytes) == dim * 4
#
# The cell has no header. The dimension is a property of the column, not of a
# cell, and it is written once, in the snapshot manifest
# (`KgManifestBody.embedding_dim`); `unpack_embedding_checked` is the reader
# that holds a cell to it. A string column is the one variable-length-bytes
# column the Parquet writer round-trips, which is why the vector rides in one.
#
# PRECISION: f32 storage, f64 compute. `pack_embedding` takes the caller's
# `List[Float64]` and narrows each component to f32, so f64 -> f32 -> f64 is
# lossy by exactly the f32 narrowing (about 1e-7 relative). `pack_embedding_f32`
# packs a `List[Float32]` bit-exactly. Little-endian is the byte order of the
# Parquet PLAIN f32 encoding, so the same bytes can later be read as a native
# FLOAT32 column without a re-pack.
#
# NULL BYTES: packed f32 bytes routinely contain 0x00 (a 0.0 component is four
# of them). They survive a `String` built with `StringSlice(unsafe_from_utf8=)`
# and read back with `.as_bytes()`, both length-based. A reader that takes a
# cell out of a string column must use the length-based byte view
# (`StringArray.get_span`) and `unpack_embedding_bytes`, never an accessor that
# returns a null-terminated string: that would cut the cell at the first 0x00.
# =============================================================================

from std.memory import bitcast


# The byte width of one packed component: f32 is 4 bytes.
comptime EMB_F32_BYTES: Int = 4

# The dimension a graph has when its manifest does not say (a manifest written
# before the dimension was recorded) and the default for a new one.
comptime DEFAULT_EMBEDDING_DIM: Int = 1536


def pack_embedding(v: List[Float64]) -> String:
    """Pack a float vector into a packed-f32 `String`.

    Each component is narrowed to f32 and emitted as 4 little-endian bytes, so
    `len(result.as_bytes()) == len(v) * 4`. The inverse is `unpack_embedding`.

    Args:
        v: The embedding vector in the caller's f64 compute type.

    Returns:
        A `String` carrying the packed bytes (`dim * 4` of them).
    """
    var f32v = List[Float32](capacity=len(v))
    for i in range(len(v)):
        f32v.append(Float32(v[i]))
    return pack_embedding_f32(f32v)


def pack_embedding_f32(v: List[Float32]) -> String:
    """Pack an f32 vector into a packed-f32 `String`, bit-exactly.

    Args:
        v: The embedding vector in f32.

    Returns:
        A `String` carrying the packed bytes (`dim * 4` of them).
    """
    var bytes = List[UInt8](capacity=len(v) * EMB_F32_BYTES)
    for i in range(len(v)):
        var u = bitcast[DType.uint32](v[i])
        bytes.append(UInt8(Int(u & UInt32(0xFF))))
        bytes.append(UInt8(Int((u >> UInt32(8)) & UInt32(0xFF))))
        bytes.append(UInt8(Int((u >> UInt32(16)) & UInt32(0xFF))))
        bytes.append(UInt8(Int((u >> UInt32(24)) & UInt32(0xFF))))
    # The bytes are binary, not text. `String` carries them
    # unchanged and every reader here goes through `.as_bytes()`; nothing treats
    # the value as text.
    return String(StringSlice(unsafe_from_utf8=Span[UInt8](bytes)))


def unpack_embedding_bytes[
    o: Origin[mut=False]
](packed: Span[UInt8, o]) -> List[Float64]:
    """Unpack little-endian f32 bytes into an f64 vector.

    The dimension is `len(packed) // 4`. Trailing bytes that do not form a whole
    f32 are ignored; use `unpack_embedding_checked` to refuse them.

    Parameters:
        o: The origin of the borrowed byte view.

    Args:
        packed: A length-based byte view over the packed cell.

    Returns:
        The vector widened to f64.
    """
    var dim = len(packed) // EMB_F32_BYTES
    var out = List[Float64](capacity=dim)
    for i in range(dim):
        var base = i * EMB_F32_BYTES
        var u = (
            UInt32(Int(packed[base]))
            | (UInt32(Int(packed[base + 1])) << UInt32(8))
            | (UInt32(Int(packed[base + 2])) << UInt32(16))
            | (UInt32(Int(packed[base + 3])) << UInt32(24))
        )
        out.append(Float64(bitcast[DType.float32](u)))
    return out^


def unpack_embedding(packed: String) -> List[Float64]:
    """Unpack a packed-f32 `String` into an f64 vector.

    The inverse of `pack_embedding` (exact up to the f32 narrowing) and of
    `pack_embedding_f32` (exact).

    Args:
        packed: A `String` made by `pack_embedding` or `pack_embedding_f32`.

    Returns:
        The vector widened to f64.
    """
    return unpack_embedding_bytes(packed.as_bytes())


def unpack_embedding_checked[
    o: Origin[mut=False]
](packed: Span[UInt8, o], dim: Int) raises -> List[Float64]:
    """Unpack a cell and refuse it unless it holds exactly `dim` components.

    This is the reader for a cell of a graph whose manifest says its dimension
    is `dim`: a cell of any other length is a vector from another model or a
    truncated cell, and is an error rather than a vector of the wrong size.

    Parameters:
        o: The origin of the borrowed byte view.

    Args:
        packed: A length-based byte view over the packed cell.
        dim: The dimension the cell must have (more than zero).

    Returns:
        The vector widened to f64, `dim` components long.
    """
    if dim <= 0:
        raise Error(
            "unpack_embedding_checked: dimension must be positive, got "
            + String(dim)
        )
    # Compared by division so a huge `dim` cannot overflow `dim * 4` and wrap
    # to a length an empty cell would match.
    if len(packed) % EMB_F32_BYTES != 0 or len(packed) // EMB_F32_BYTES != dim:
        raise Error(
            "unpack_embedding_checked: embedding cell is "
            + String(len(packed))
            + " bytes, which is not a dimension of "
            + String(dim)
            + " (4 bytes per component)"
        )
    return unpack_embedding_bytes(packed)
