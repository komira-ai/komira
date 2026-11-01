# =============================================================================
# Blocking functions for large-scale non-equi joins
# =============================================================================
#
# A BlockingFunction maps each row to one or more bucket IDs. Rows on both
# sides that share a bucket ID are candidate pairs; rows in different buckets
# are guaranteed NOT to match. This converts a theta join to a hash join on
# bucket ID with a residual predicate.
#
# A theta join without equi-keys or a blocking function is refused before it
# reaches the engine: there is no nested-loop escape hatch.
#
# Built-in implementations:
#   - BinBlocking:     Fixed-width bins for range/band joins.
#   - GeohashBlocking: Geospatial proximity via geohash bucketing.
# =============================================================================

from std.math import floor


# =============================================================================
# BinBlocking
# =============================================================================


struct BinBlocking(Movable, Copyable):
    """Fixed-width binning blocking function for range/band joins.

    Maps each numeric value to a bin ID: bin_id = floor(value / bin_width).
    For range columns (lo, hi), maps to all bins that the range overlaps:
    bins = floor(lo / bin_width)..=floor(hi / bin_width).

    Choosing bin_width:
    - Too small: many bins per range row = high candidate fan-out.
    - Too large: many rows per bin = poor candidate reduction.
    - Rule of thumb: bin_width = (max - min) / sqrt(N) where N is the
      smaller side's row count.

    """

    var value_col: Int
    var lo_col: Int
    var hi_col: Int
    var bin_width: Float64
    var is_range: Bool

    def __init__(out self, value_col: Int, lo_col: Int, hi_col: Int,
                 bin_width: Float64, is_range: Bool):
        self.value_col = value_col
        self.lo_col = lo_col
        self.hi_col = hi_col
        self.bin_width = bin_width
        self.is_range = is_range

    @staticmethod
    def for_point(column_index: Int, bin_width: Float64) -> BinBlocking:
        """Create a BinBlocking for point values (one bin per row).

        Each value maps to floor(value / bin_width) as a single bucket ID.

        Args:
            column_index: Column index of the value to bin.
            bin_width: Width of each bin. Must be positive.
        """
        debug_assert(bin_width > 0.0, "bin_width must be positive")
        return BinBlocking(
            value_col=column_index,
            lo_col=-1,
            hi_col=-1,
            bin_width=bin_width,
            is_range=False,
        )

    @staticmethod
    def for_range(lo_col: Int, hi_col: Int, bin_width: Float64) -> BinBlocking:
        """Create a BinBlocking for range values (multiple bins per row).

        Each row with range [lo, hi] maps to all bins from
        floor(lo / bin_width) to floor(hi / bin_width).

        Args:
            lo_col: Column index for range lower bound.
            hi_col: Column index for range upper bound.
            bin_width: Width of each bin. Must be positive.
        """
        debug_assert(bin_width > 0.0, "bin_width must be positive")
        return BinBlocking(
            value_col=-1,
            lo_col=lo_col,
            hi_col=hi_col,
            bin_width=bin_width,
            is_range=True,
        )

    @always_inline
    def value_to_bin(self, value: Float64) -> UInt64:
        """Convert a floating-point value to a bin ID.

        Uses floor(value / bin_width) and maps to UInt64.
        Negative values produce distinct bin IDs via wrapping arithmetic.
        """
        var bin = Int64(floor(value / self.bin_width))
        return UInt64(bin)

    def block_keys_point(self, values: Span[Float64, _]) -> List[List[UInt64]]:
        """Compute block keys for point values.

        Each row maps to exactly one bin. Null handling is the caller's
        responsibility (pass only non-null values).

        Args:
            values: The Float64 values, one per row.

        Returns:
            List of List[UInt64] where each inner list has exactly 1 element.
        """
        var keys = List[List[UInt64]]()
        for i in range(len(values)):
            var bin = self.value_to_bin(values[i])
            var bucket: List[UInt64] = [bin]
            keys.append(bucket^)
        return keys^

    def block_keys_range(
        self, lo_vals: Span[Float64, _], hi_vals: Span[Float64, _]
    ) raises -> List[List[UInt64]]:
        """Compute block keys for range values.

        Each row maps to all bins overlapping [lo, hi].

        Args:
            lo_vals: The lower bounds, one per row.
            hi_vals: The upper bounds, one per row.

        Returns:
            List of List[UInt64] where each inner list has the overlapping bins.

        Raises:
            When the two spans differ in length.
        """
        if len(lo_vals) != len(hi_vals):
            raise Error("BinBlocking.block_keys_range: lo and hi lengths differ")
        var num_rows = len(lo_vals)
        var keys = List[List[UInt64]]()
        for i in range(num_rows):
            var lo_bin = Int64(floor(lo_vals[i] / self.bin_width))
            var hi_bin = Int64(floor(hi_vals[i] / self.bin_width))
            var bucket = List[UInt64]()
            var b = lo_bin
            while b <= hi_bin:
                bucket.append(UInt64(b))
                b += 1
            keys.append(bucket^)
        return keys^

    def name(self) -> String:
        return "bin_blocking"


# =============================================================================
# Geohash encoding utilities
# =============================================================================


@always_inline
def _quantize(value: Float64, min_val: Float64, max_val: Float64,
              bits: UInt32) -> UInt64:
    """Quantize a value in [min, max] to a bits-bit integer.

    Args:
        value: Value to quantize.
        min_val: Minimum of the range.
        max_val: Maximum of the range.
        bits: Number of bits for the output.

    Returns:
        Quantized integer in [0, 2^bits - 1].
    """
    var range_val = max_val - min_val
    var normalized = (value - min_val) / range_val
    # Clamp to [0, 1].
    if normalized < 0.0:
        normalized = 0.0
    elif normalized > 1.0:
        normalized = 1.0
    var max_int = (UInt64(1) << UInt64(bits)) - 1
    return UInt64(normalized * Float64(max_int))


@always_inline
def _interleave(a_code: UInt64, b_code: UInt64,
                a_bits: UInt32, b_bits: UInt32) -> UInt64:
    """Interleave two codes: a into even positions, b into odd positions.

    For geohash: longitude goes into even bits, latitude into odd bits.

    Args:
        a_code: Code for even positions (longitude).
        b_code: Code for odd positions (latitude).
        a_bits: Number of bits in a_code.
        b_bits: Number of bits in b_code.

    Returns:
        Interleaved u64 hash.
    """
    var total_bits = Int(a_bits) + Int(b_bits)
    var result = UInt64(0)
    var a_idx = Int(0)
    var b_idx = Int(0)

    for i in range(total_bits):
        if i % 2 == 0:
            # Even bit: from a (longitude).
            if a_idx < Int(a_bits):
                var shift = Int(a_bits) - 1 - a_idx
                var bit = (a_code >> UInt64(shift)) & 1
                result = result | (bit << UInt64(total_bits - 1 - i))
                a_idx += 1
        else:
            # Odd bit: from b (latitude).
            if b_idx < Int(b_bits):
                var shift = Int(b_bits) - 1 - b_idx
                var bit = (b_code >> UInt64(shift)) & 1
                result = result | (bit << UInt64(total_bits - 1 - i))
                b_idx += 1

    return result


@always_inline
def _deinterleave(hash: UInt64, a_bits: UInt32, b_bits: UInt32) -> Tuple[UInt64, UInt64]:
    """Deinterleave a hash back to (a_code, b_code).

    Args:
        hash: Interleaved hash.
        a_bits: Number of bits for a (even positions).
        b_bits: Number of bits for b (odd positions).

    Returns:
        Tuple of (a_code, b_code).
    """
    var total_bits = Int(a_bits) + Int(b_bits)
    var a_code = UInt64(0)
    var b_code = UInt64(0)
    var a_idx = Int(0)
    var b_idx = Int(0)

    for i in range(total_bits):
        var bit = (hash >> UInt64(total_bits - 1 - i)) & 1
        if i % 2 == 0:
            if a_idx < Int(a_bits):
                var shift = Int(a_bits) - 1 - a_idx
                a_code = a_code | (bit << UInt64(shift))
                a_idx += 1
        else:
            if b_idx < Int(b_bits):
                var shift = Int(b_bits) - 1 - b_idx
                b_code = b_code | (bit << UInt64(shift))
                b_idx += 1

    return (a_code, b_code)


def geohash_encode(lat: Float64, lon: Float64, precision: UInt8) -> UInt64:
    """Encode (lat, lon) to a geohash as a u64 value.

    The geohash interleaves bits of longitude and latitude, with longitude
    getting the even bits and latitude the odd bits. Each precision level
    adds 5 bits (from a base32 character).

    This is a simplified integer encoding -- we don't convert to base32
    strings. The u64 representation is sufficient for bucket ID purposes.

    Args:
        lat: Latitude (-90 to 90).
        lon: Longitude (-180 to 180).
        precision: Geohash precision (1-8).

    Returns:
        Geohash as a u64.
    """
    var total_bits = UInt32(precision) * 5
    var lat_bits = total_bits / 2
    var lon_bits = total_bits - lat_bits

    var lat_code = _quantize(lat, -90.0, 90.0, lat_bits)
    var lon_code = _quantize(lon, -180.0, 180.0, lon_bits)

    return _interleave(lon_code, lat_code, lon_bits, lat_bits)


def geohash_neighbors(hash: UInt64, precision: UInt8) -> InlineArray[UInt64, 8]:
    """Compute the 8 neighbor geohash cells of the given cell.

    Returns an array of 8 neighbor hashes. Invalid neighbors (outside
    valid coordinate range) are set to UInt64.MAX.

    Args:
        hash: The center cell's geohash.
        precision: Geohash precision (1-8).

    Returns:
        InlineArray of 8 neighbor hashes.
    """
    var total_bits = UInt32(precision) * 5
    var lat_bits = total_bits / 2
    var lon_bits = total_bits - lat_bits

    var codes = _deinterleave(hash, lon_bits, lat_bits)
    var lon_code = codes[0]
    var lat_code = codes[1]

    var lat_max = (UInt64(1) << UInt64(lat_bits)) - 1
    var lon_max = (UInt64(1) << UInt64(lon_bits)) - 1

    # 8 directions: N, NE, E, SE, S, SW, W, NW
    # (dlon, dlat) pairs.
    var neighbors = InlineArray[UInt64, 8](uninitialized=True)
    comptime SENTINEL: UInt64 = ~UInt64(0)  # UInt64.MAX

    # Initialize all to sentinel.
    for idx in range(8):
        neighbors[idx] = SENTINEL

    # Direction deltas: (dlon, dlat)
    # N=(0,1), NE=(1,1), E=(1,0), SE=(1,-1), S=(0,-1), SW=(-1,-1), W=(-1,0), NW=(-1,1)
    var dlon = InlineArray[Int, 8](uninitialized=True)
    var dlat = InlineArray[Int, 8](uninitialized=True)
    dlon[0] = 0;  dlat[0] = 1    # N
    dlon[1] = 1;  dlat[1] = 1    # NE
    dlon[2] = 1;  dlat[2] = 0    # E
    dlon[3] = 1;  dlat[3] = -1   # SE
    dlon[4] = 0;  dlat[4] = -1   # S
    dlon[5] = -1; dlat[5] = -1   # SW
    dlon[6] = -1; dlat[6] = 0    # W
    dlon[7] = -1; dlat[7] = 1    # NW

    var lon_i = Int(lon_code)
    var lat_i = Int(lat_code)

    for idx in range(8):
        var new_lon = lon_i + dlon[idx]
        var new_lat = lat_i + dlat[idx]

        # Latitude does NOT wrap (poles are boundaries).
        if new_lat < 0 or new_lat > Int(lat_max):
            continue  # Keep sentinel (UInt64.MAX).

        # Longitude wraps around (Earth is a sphere).
        var wrapped_lon: Int
        if new_lon < 0:
            wrapped_lon = Int(lon_max) + new_lon + 1
        elif new_lon > Int(lon_max):
            wrapped_lon = new_lon - Int(lon_max) - 1
        else:
            wrapped_lon = new_lon

        neighbors[idx] = _interleave(
            UInt64(wrapped_lon), UInt64(new_lat), lon_bits, lat_bits
        )

    return neighbors^


# =============================================================================
# GeohashBlocking
# =============================================================================


struct GeohashBlocking(Movable, Copyable):
    """Geohash-based blocking for geospatial proximity joins.

    Maps (lat, lon) to a geohash cell and its 8 neighbors, ensuring that
    points near cell borders are still considered as candidates.

    Precision guide:
      2: ~1250 km (continent)
      3: ~156 km  (region)
      4: ~39 km   (metro)
      5: ~5 km    (district)
      6: ~1.2 km  (neighborhood)
      7: ~150 m   (block)

    """

    var lat_col: Int
    var lon_col: Int
    var precision: UInt8

    def __init__(out self, lat_col: Int, lon_col: Int, precision: UInt8):
        debug_assert(precision >= 1 and precision <= 8, "precision must be 1..=8")
        self.lat_col = lat_col
        self.lon_col = lon_col
        self.precision = precision

    def block_keys(
        self, lat_vals: Span[Float64, _], lon_vals: Span[Float64, _]
    ) raises -> List[List[UInt64]]:
        """Compute block keys for geospatial points.

        Each point maps to its geohash cell plus up to 8 neighbor cells
        for border completeness.

        Args:
            lat_vals: The latitudes, one per row.
            lon_vals: The longitudes, one per row.

        Returns:
            List of List[UInt64] where each inner list has up to 9 bucket IDs.

        Raises:
            When the two spans differ in length.
        """
        comptime SENTINEL: UInt64 = ~UInt64(0)

        if len(lat_vals) != len(lon_vals):
            raise Error("GeohashBlocking.block_keys: lat and lon lengths differ")
        var num_rows = len(lat_vals)
        var keys = List[List[UInt64]]()
        for i in range(num_rows):
            var lat = lat_vals[i]
            var lon = lon_vals[i]

            var hash = geohash_encode(lat, lon, self.precision)
            var nbrs = geohash_neighbors(hash, self.precision)

            # Include self + valid neighbors (up to 9 total).
            var bucket = List[UInt64]()
            bucket.append(hash)
            for j in range(8):
                if nbrs[j] != SENTINEL:
                    bucket.append(nbrs[j])
            keys.append(bucket^)
        return keys^

    def name(self) -> String:
        return "geohash_blocking"
