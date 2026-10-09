# =============================================================================
# src/komira_http_core/codec/h2/hpack.mojo — RFC 7541 HPACK encoder + decoder
# =============================================================================
#
#
# Pure-Mojo HPACK (RFC 7541):
#   * Integer codec (5/6/7-bit prefix variants)
#   * String codec (raw + Huffman per RFC 7541 Appendix B; the Huffman
#     tables and decoder live in hpack_huffman.mojo)
#   * Static table (61 entries; RFC 7541 Appendix A)
#   * Dynamic table (size-bounded, FIFO eviction)
#   * 4 header-field representations (indexed, literal-incremental,
#     literal-no-index, literal-never-indexed)
#   * Dynamic-table-size update
#   * `pending_min` / `pending_final` two-field pipeline for SETTINGS_HEADER_TABLE_SIZE
#     concurrency
#
# No UnsafePointer in any public sig. No wildcard origin. No
# `unsafe_from_address`. Pointer audit: `_HpackEntry` carries `String × 2`
# heap-owning fields; lives only in `List[_HpackEntry]` (NOT in any
# byte-backed slab). Safe per the pointer rules.
# =============================================================================

from .hpack_huffman import huffman_decode_octets


# =============================================================================
# §1 — Static table (RFC 7541 Appendix A).
# =============================================================================
# 61 entries; index 1..61 (HPACK is 1-indexed, with 0 = unused sentinel).
# Implemented as a function that returns (name, value) for an index.
# Some entries are name-only (value is empty string).


def hpack_static_lookup(index: Int) -> Tuple[String, String]:
    """Look up a static-table entry. Returns (name, value); empty-value
    entries return ("", "") for both — caller distinguishes via length.

    Indices are 1-based per RFC 7541 §2.3.1. Out-of-range returns
    ("", "")."""
    if index == 1:
        return (String(":authority"), String(""))
    if index == 2:
        return (String(":method"), String("GET"))
    if index == 3:
        return (String(":method"), String("POST"))
    if index == 4:
        return (String(":path"), String("/"))
    if index == 5:
        return (String(":path"), String("/index.html"))
    if index == 6:
        return (String(":scheme"), String("http"))
    if index == 7:
        return (String(":scheme"), String("https"))
    if index == 8:
        return (String(":status"), String("200"))
    if index == 9:
        return (String(":status"), String("204"))
    if index == 10:
        return (String(":status"), String("206"))
    if index == 11:
        return (String(":status"), String("304"))
    if index == 12:
        return (String(":status"), String("400"))
    if index == 13:
        return (String(":status"), String("404"))
    if index == 14:
        return (String(":status"), String("500"))
    if index == 15:
        return (String("accept-charset"), String(""))
    if index == 16:
        return (String("accept-encoding"), String("gzip, deflate"))
    if index == 17:
        return (String("accept-language"), String(""))
    if index == 18:
        return (String("accept-ranges"), String(""))
    if index == 19:
        return (String("accept"), String(""))
    if index == 20:
        return (String("access-control-allow-origin"), String(""))
    if index == 21:
        return (String("age"), String(""))
    if index == 22:
        return (String("allow"), String(""))
    if index == 23:
        return (String("authorization"), String(""))
    if index == 24:
        return (String("cache-control"), String(""))
    if index == 25:
        return (String("content-disposition"), String(""))
    if index == 26:
        return (String("content-encoding"), String(""))
    if index == 27:
        return (String("content-language"), String(""))
    if index == 28:
        return (String("content-length"), String(""))
    if index == 29:
        return (String("content-location"), String(""))
    if index == 30:
        return (String("content-range"), String(""))
    if index == 31:
        return (String("content-type"), String(""))
    if index == 32:
        return (String("cookie"), String(""))
    if index == 33:
        return (String("date"), String(""))
    if index == 34:
        return (String("etag"), String(""))
    if index == 35:
        return (String("expect"), String(""))
    if index == 36:
        return (String("expires"), String(""))
    if index == 37:
        return (String("from"), String(""))
    if index == 38:
        return (String("host"), String(""))
    if index == 39:
        return (String("if-match"), String(""))
    if index == 40:
        return (String("if-modified-since"), String(""))
    if index == 41:
        return (String("if-none-match"), String(""))
    if index == 42:
        return (String("if-range"), String(""))
    if index == 43:
        return (String("if-unmodified-since"), String(""))
    if index == 44:
        return (String("last-modified"), String(""))
    if index == 45:
        return (String("link"), String(""))
    if index == 46:
        return (String("location"), String(""))
    if index == 47:
        return (String("max-forwards"), String(""))
    if index == 48:
        return (String("proxy-authenticate"), String(""))
    if index == 49:
        return (String("proxy-authorization"), String(""))
    if index == 50:
        return (String("range"), String(""))
    if index == 51:
        return (String("referer"), String(""))
    if index == 52:
        return (String("refresh"), String(""))
    if index == 53:
        return (String("retry-after"), String(""))
    if index == 54:
        return (String("server"), String(""))
    if index == 55:
        return (String("set-cookie"), String(""))
    if index == 56:
        return (String("strict-transport-security"), String(""))
    if index == 57:
        return (String("transfer-encoding"), String(""))
    if index == 58:
        return (String("user-agent"), String(""))
    if index == 59:
        return (String("vary"), String(""))
    if index == 60:
        return (String("via"), String(""))
    if index == 61:
        return (String("www-authenticate"), String(""))
    return (String(""), String(""))


comptime HPACK_STATIC_TABLE_SIZE: Int = 61


# =============================================================================
# §2 — Representation discriminators.
# =============================================================================

comptime HPACK_REPR_INDEXED: UInt8 = 0           # 1xxxxxxx
comptime HPACK_REPR_LITERAL_INCREMENTAL: UInt8 = 1  # 01xxxxxx
comptime HPACK_REPR_LITERAL_NO_INDEX: UInt8 = 2     # 0000xxxx
comptime HPACK_REPR_LITERAL_NEVER: UInt8 = 3        # 0001xxxx
comptime HPACK_REPR_SIZE_UPDATE: UInt8 = 4          # 001xxxxx


# =============================================================================
# §3 — Integer codec (RFC 7541 §5.1).
# =============================================================================

# UNTRUSTED-INPUT CEILINGS.
#
# A 32-bit HPACK integer carries 7 value bits per continuation octet, so the
# widest legal encoding is prefix + 5 continuation octets (shifts 0/7/14/21/28).
# A 6th octet shifts by 35, which is out of range for UInt32.
comptime _HPACK_MAX_CONTINUATION_OCTETS: Int = 5

# RFC 9113 §6.5.2 SETTINGS_MAX_HEADER_LIST_SIZE accounting unit: each field
# costs `len(name) + len(value) + 32` "overhead" octets.
comptime HPACK_HEADER_ENTRY_OVERHEAD: Int = 32

# Default ceiling on the DECODED header list of one block. Both the server
# (transport/serve_h2.mojo) and the client (client/h2_client.mojo) ADVERTISE
# SETTINGS_MAX_HEADER_LIST_SIZE = 8192; this default is deliberately 8x that so
# a peer that merely rounds up is not disconnected, while the amplification a
# hostile peer can buy stays bounded. One INDEXED representation is ONE octet on
# the wire and materialises a whole heap-owning (name, value) pair, so without
# this ceiling a 16 KiB block mints ~16k String pairs — and the block itself is
# fed from an unbounded CONTINUATION reassembly buffer.
comptime HPACK_DEFAULT_MAX_HEADER_LIST_SIZE: Int = 65536


def encode_integer(
    value: UInt32,
    prefix_bits: Int,
    first_byte_high_bits: UInt8,
    mut out: List[UInt8],
):
    """Encode an integer per RFC 7541 §5.1.

    `prefix_bits` is N ∈ [1..8]; `first_byte_high_bits` is the high
    (8 - N) bits of the first byte (e.g., 0x80 for `1xxxxxxx`).

    If value < 2**N - 1, encoded as one byte with value in the low N bits.
    Else, the low N bits are all-1s and the remainder is encoded as
    a sequence of bytes per the continuation rule.
    """
    var max_prefix = (UInt32(1) << UInt32(prefix_bits)) - UInt32(1)
    if value < max_prefix:
        out.append(first_byte_high_bits | UInt8(Int(value)))
        return
    out.append(first_byte_high_bits | UInt8(Int(max_prefix)))
    var v = value - max_prefix
    while v >= UInt32(128):
        out.append(UInt8(Int((v & UInt32(0x7f)) | UInt32(0x80))))
        v = v >> 1
        v = v >> 1
        v = v >> 1
        v = v >> 1
        v = v >> 1
        v = v >> 1
        v = v >> 1
        # equivalent to v >> 7 in 7 steps to avoid potential codegen
        # surprise with shift-by-comptime-int on UInt32
    out.append(UInt8(Int(v)))


@fieldwise_init
struct _IntegerDecodeResult(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    var value: UInt32
    var consumed: Int
    var ok: Bool


def decode_integer(
    buf: Span[UInt8, _],
    start: Int,
    prefix_bits: Int,
) -> _IntegerDecodeResult:
    """Decode an integer per RFC 7541 §5.1.

    The high (8 - N) bits of the first byte are ignored (they're the
    representation discriminator the caller already matched).

    Returns (value, consumed, ok). `ok=False` if the buffer is truncated
    or the encoding is malformed (>5 continuation bytes; RFC limit).
    """
    var n = len(buf)
    if start >= n:
        return _IntegerDecodeResult(value=UInt32(0), consumed=0, ok=False)
    var max_prefix = (UInt32(1) << UInt32(prefix_bits)) - UInt32(1)
    var b0 = UInt32(Int(buf[start])) & max_prefix
    if b0 < max_prefix:
        return _IntegerDecodeResult(value=b0, consumed=1, ok=True)
    var value: UInt32 = max_prefix
    var m: UInt32 = UInt32(0)
    var i = start + 1
    var cont_count = 0
    while i < n:
        # ── UNTRUSTED-INPUT CEILING ──
        # A 32-bit HPACK integer needs AT MOST 5 continuation octets
        # (7 value bits each: shift amounts 0, 7, 14, 21, 28). A 6th octet
        # evaluates `<< 35` on a UInt32 — an out-of-range shift. With this check
        # AFTER the shift, `FF 80 80 80 80 80 80` (a
        # 7-byte HEADERS payload any peer can send) would reach iteration 6 with
        # m == 35, bounded by nothing in our own code.
        #
        # ⚠ HONESTY NOTE, measured on Mojo 1.0.0b2: that input, run against a
        # decoder WITHOUT this bound in BOTH configurations, misbehaved in
        # NEITHER:
        # ASSERT=safe did NOT abort (so there is no firing `debug_assert`
        # inside `SIMD.__lshift__` here), and ASSERT=none produced no
        # observable corruption (the shift result is folded into `value` and
        # then discarded, because iteration 6 returns `ok=False` regardless).
        # This bound is therefore retained on PRINCIPLE — an out-of-range
        # shift is UB an optimiser may exploit, and the check costs one
        # compare — NOT as a fix for a demonstrated vulnerability. The
        # demonstrated defect at this site is the wrap guarded just below.
        if cont_count >= _HPACK_MAX_CONTINUATION_OCTETS:
            return _IntegerDecodeResult(
                value=UInt32(0), consumed=0, ok=False,
            )
        var b = UInt32(Int(buf[i]))
        var seven = b & UInt32(0x7f)
        # RFC 7541 §5.1: "a decoder MUST treat a value that exceeds the
        # implementation limit ... as a decoding error". Our limit is
        # 2^32 - 1 (the `UInt32` the field is decoded into), so BOTH the
        # shift-out-of-the-top and the sum wrapping are decoding errors —
        # previously `value = value + addend` wrapped silently, letting a
        # hostile encoder land any 32-bit value it liked on a length or an
        # index that the caller then treats as validated.
        if m == UInt32(28) and seven > UInt32(0x0f):
            return _IntegerDecodeResult(
                value=UInt32(0), consumed=0, ok=False,
            )
        var addend = seven << m
        var summed = value + addend
        if summed < value:
            return _IntegerDecodeResult(
                value=UInt32(0), consumed=0, ok=False,
            )
        value = summed
        i = i + 1
        cont_count = cont_count + 1
        if (b & UInt32(0x80)) == UInt32(0):
            return _IntegerDecodeResult(
                value=value, consumed=i - start, ok=True,
            )
        m = m + UInt32(7)
    return _IntegerDecodeResult(value=UInt32(0), consumed=0, ok=False)


# =============================================================================
# §4 — String codec (RFC 7541 §5.2).
# =============================================================================
# The decoder accepts raw and Huffman-coded literals (RFC 7541 §5.2 lets an
# encoder pick either); the encoder emits raw literals only.


def encode_string(
    s: String,
    use_huffman: Bool,
    mut out: List[UInt8],
):
    """Encode an HPACK string literal (RFC 7541 §5.2).

    Wire format:
        H | Length (7+ prefix int)
        Octets...

    raw only. The use_huffman knob is wired but defaults False; the
    full Huffman encoder is non-MVP (a follow-up optimization slot).
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    if use_huffman:
        # Huffman encoder TODO; for now we always emit raw. The bit is
        # ignored to maintain the type surface for callers that want to
        # opt in later.
        encode_integer(UInt32(n), 7, UInt8(0), out)
    else:
        encode_integer(UInt32(n), 7, UInt8(0), out)
    var i = 0
    while i < n:
        out.append(bytes[i])
        i = i + 1


@fieldwise_init
struct _StringDecodeResult(Movable, Deinitable):
    var value: String
    var consumed: Int
    var ok: Bool


def hpack_octets_to_string(octets: List[UInt8]) -> String:
    """The String a decoded HPACK string literal's octets become.

    RFC 7541 §5.2: a string literal is a sequence of octets. When those
    octets are well-formed UTF-8 the String holds exactly them (`c3 a9` is
    the two octets of "é"). A Mojo String must be UTF-8, so octets that are
    not (obs-text such as a lone 0x80 or 0xff, or a truncated sequence) are
    mapped one code point per octet, U+0000..U+00FF, the mapping the h1
    parser applies to obs-text; such a value reads back longer than its
    wire form.
    """
    try:
        return String(StringSlice(from_utf8=Span(octets)))
    except:
        var s = String()
        for i in range(len(octets)):
            s += chr(Int(octets[i]))
        return s^


def decode_string(
    buf: Span[UInt8, _],
    start: Int,
) -> _StringDecodeResult:
    """Decode an HPACK string literal (RFC 7541 §5.2).

    Reads the H flag (MSB of the first octet) and the 7-bit-prefix length,
    then `length` octets: Huffman-coded (Appendix B, every octet and EOS,
    see hpack_huffman.mojo) when H is 1, raw when H is 0. The octets become
    the value through `hpack_octets_to_string`. `ok` is False when the
    length or the octets run past `buf`, or the Huffman data is invalid.
    """
    var out = _StringDecodeResult(
        value=String(), consumed=0, ok=False,
    )
    var n = len(buf)
    if start >= n:
        return out^
    var is_huffman = (UInt32(Int(buf[start])) & UInt32(0x80)) != UInt32(0)
    var lenres = decode_integer(buf, start, 7)
    if not lenres.ok:
        return out^
    var slen = Int(lenres.value)
    var data_off = start + lenres.consumed
    if data_off + slen > n:
        return out^
    if is_huffman:
        var decoded = huffman_decode_octets(buf, data_off, slen)
        if not decoded[1]:
            return out^
        out.value = hpack_octets_to_string(decoded[0])
    else:
        var raw = List[UInt8](capacity=slen)
        for i in range(slen):
            raw.append(buf[data_off + i])
        out.value = hpack_octets_to_string(raw)
    out.consumed = lenres.consumed + slen
    out.ok = True
    return out^


# =============================================================================
# §6 — Dynamic table.
# =============================================================================


struct _HpackEntry(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Single HPACK dynamic-table entry.

    Copyable so it lives in `List[_HpackEntry]` (Mojo 1.0.0b1 requires
    `T: Copyable` for List storage). The two String fields are Copyable;
    `entry_size` is computed at construction so subsequent eviction loops
    don't re-walk the bytes.
    """
    var name: String
    var value: String
    var entry_size: Int  # len(name) + len(value) + 32

    def __init__(out self):
        self.name = String()
        self.value = String()
        self.entry_size = 32

    def __init__(out self, var name: String, var value: String):
        var n = len(name.as_bytes())
        var v = len(value.as_bytes())
        self.name = name^
        self.value = value^
        self.entry_size = n + v + 32


struct HpackDynamicTable(Movable, Deinitable):
    """HPACK dynamic table — FIFO with size-based eviction.

    Entries are stored newest-first at index 0 (matches RFC 7541 §2.3.3's
    indexing convention).
    """

    var entries: List[_HpackEntry]
    var size: Int       # current total entry size in HPACK units
    var max_size: Int   # SETTINGS_HEADER_TABLE_SIZE limit (initial 4096)

    def __init__(out self):
        self.entries = List[_HpackEntry]()
        self.size = 0
        self.max_size = 4096

    def __init__(out self, max_size: Int):
        self.entries = List[_HpackEntry]()
        self.size = 0
        self.max_size = max_size

    def count(self) -> Int:
        return len(self.entries)

    def lookup(self, index_in_dynamic: Int) -> Tuple[String, String]:
        """Look up dynamic table entry. `index_in_dynamic` is 0-based
        from-newest; HPACK callers must convert from the 1-based HPACK
        index (subtract STATIC_TABLE_SIZE) before calling."""
        if index_in_dynamic < 0 or index_in_dynamic >= len(self.entries):
            return (String(""), String(""))
        var e = self.entries[index_in_dynamic]
        return (String(e.name), String(e.value))

    def add(mut self, var name: String, var value: String):
        """Add a new entry at the head. Evicts from tail to maintain
        size ≤ max_size. If the new entry alone exceeds max_size, the
        table is cleared (RFC 7541 §4.4)."""
        var ent_size = len(name.as_bytes()) + len(value.as_bytes()) + 32
        # Pre-evict: ensure (current size + new entry) ≤ max_size by
        # evicting from the tail.
        while (
            self.size + ent_size > self.max_size and len(self.entries) > 0
        ):
            var last_idx = len(self.entries) - 1
            self.size = self.size - self.entries[last_idx].entry_size
            # Pop tail. Use stdlib pop().
            _ = self.entries.pop()
        if ent_size > self.max_size:
            # Entry too big — leave table empty.
            return
        var ent = _HpackEntry(name^, value^)
        # Insert at head: build a new list with the new entry first, then
        # the existing entries (Copyable so List can copy them): small
        # table sizes so O(n) shift is fine.
        var new_entries = List[_HpackEntry]()
        new_entries.append(ent^)
        var i = 0
        while i < len(self.entries):
            new_entries.append(self.entries[i])
            i = i + 1
        self.entries = new_entries^
        self.size = self.size + ent_size

    def set_max_size(mut self, new_max: Int):
        """Update max_size and evict if necessary (RFC 7541 §4.3).

        Caller emits the on-wire dynamic-table-size-update separately;
        this method just adjusts internal storage.
        """
        self.max_size = new_max
        while self.size > self.max_size and len(self.entries) > 0:
            var last_idx = len(self.entries) - 1
            self.size = self.size - self.entries[last_idx].entry_size
            _ = self.entries.pop()


# (Removed: `_hpack_entry_copy` helper — _HpackEntry is now Copyable, so
# direct copy via list-indexing in `add()` works.)


# =============================================================================
# §7 — HpackHeader (decoded header pair).
# =============================================================================


struct HpackHeader(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """One decoded HPACK header (name + value).

    Copyable so `List[HpackHeader]` is well-typed in Mojo 1.0.0b1 (List
    requires `T: Copyable`). Both `name` and `value` are `String` which is
    Copyable in 1.0.0b1.
    """
    var name: String
    var value: String

    def __init__(out self):
        self.name = String()
        self.value = String()

    def __init__(out self, var name: String, var value: String):
        self.name = name^
        self.value = value^


# =============================================================================
# §8 — HpackEncoder.
# =============================================================================


struct HpackEncoder(Movable, Deinitable):
    """HPACK encoder (RFC 7541) with the two-field size-update pipeline.

    Fields:
      table       — encoder's dynamic table.
      pending_min — the minimum max-table-size seen in the interval between
                    two HEADERS blocks (ssue 1 — drains as
                    the FIRST size-update of the next block if != pending_final).
      pending_final — the current (final) max-table-size.

    Usage:
      enc.on_settings_ack_table_size(new_size)  # whenever SETTINGS_HEADER_TABLE_SIZE arrives
      enc.encode_block(headers) -> List[UInt8]  # emits pending updates then headers
    """

    var table: HpackDynamicTable
    var pending_min: Optional[UInt32]
    var pending_final: Optional[UInt32]

    def __init__(out self):
        self.table = HpackDynamicTable()
        self.pending_min = Optional[UInt32]()
        self.pending_final = Optional[UInt32]()

    def __init__(out self, max_table_size: Int):
        self.table = HpackDynamicTable(max_size=max_table_size)
        self.pending_min = Optional[UInt32]()
        self.pending_final = Optional[UInt32]()

    def on_settings_ack_table_size(mut self, new_size: UInt32):
        """Handle a SETTINGS_HEADER_TABLE_SIZE change.

        Sets pending_final = new_size and pending_min =
        min(pending_min, new_size). The next encode_block emits the
        pair (if min != final, both; otherwise just final), then clears.

        This is the data structure nghttp2 uses (`next_table_size` /
        `table_size`). The double-SETTINGS test in acceptance fires
        through these two fields.
        """
        var pm_old = self.pending_min
        if pm_old:
            var pmv = pm_old.value()
            var new_min = pmv if pmv < new_size else new_size
            self.pending_min = Optional[UInt32](new_min)
        else:
            self.pending_min = Optional[UInt32](new_size)
        self.pending_final = Optional[UInt32](new_size)

    def _drain_pending_size_updates(mut self, mut out: List[UInt8]):
        """Emit pending dynamic-table-size-update instructions at block start."""
        var pm = self.pending_min
        var pf = self.pending_final
        if pm and pf:
            var pmv = pm.value()
            var pfv = pf.value()
            if pmv != pfv:
                # Apply minimum first.
                self.table.set_max_size(Int(pmv))
                encode_integer(pmv, 5, UInt8(0x20), out)
            self.table.set_max_size(Int(pfv))
            encode_integer(pfv, 5, UInt8(0x20), out)
        elif pf:
            var pfv = pf.value()
            self.table.set_max_size(Int(pfv))
            encode_integer(pfv, 5, UInt8(0x20), out)
        self.pending_min = Optional[UInt32]()
        self.pending_final = Optional[UInt32]()

    def encode_block(
        mut self,
        var headers: List[HpackHeader],
    ) -> List[UInt8]:
        """Encode a list of headers into a single HPACK block fragment.

        Each header is emitted as a literal-incremental representation
        (add to dynamic table): no static-table lookup optimization
        on encode (correctness-first; perf follow-up).

        Size updates are drained as the FIRST bytes of the block.
        """
        var out = List[UInt8]()
        self._drain_pending_size_updates(out)
        var n = len(headers)
        var i = 0
        while i < n:
            var h = headers[i]
            # Literal-incremental: 01xxxxxx with index=0 (new name+value
            # literal). Encode index=0 in 6-bit prefix.
            out.append(UInt8(0x40))
            # Name literal.
            encode_string(String(h.name), False, out)
            # Value literal.
            encode_string(String(h.value), False, out)
            # Add to dynamic table.
            var nm_for_table = String(h.name)
            var val_for_table = String(h.value)
            self.table.add(nm_for_table^, val_for_table^)
            i = i + 1
        return out^


# =============================================================================
# §9 — HpackDecoder.
# =============================================================================


struct HpackDecoder(Movable, Deinitable):
    """HPACK decoder (RFC 7541).

    Single dynamic table; updated on every literal-incremental + on every
    dynamic-table-size-update.
    """

    var table: HpackDynamicTable
    # The SETTINGS_HEADER_TABLE_SIZE this decoder advertised (RFC 7541 §4.2,
    # §6.3): the ceiling for every dynamic table size update. It is not the
    # table's current maximum, which an update may have lowered; a later
    # update may raise the table back up to this.
    var settings_table_size: Int
    # UNTRUSTED-INPUT CEILING: the
    # RFC 9113 §6.5.2 header-list-size budget for ONE decoded block. See
    # HPACK_DEFAULT_MAX_HEADER_LIST_SIZE. Settable so a caller with a
    # tighter policy (or a test) can lower it; never unbounded.
    var max_header_list_size: Int

    def __init__(out self):
        self.table = HpackDynamicTable()
        self.settings_table_size = self.table.max_size
        self.max_header_list_size = HPACK_DEFAULT_MAX_HEADER_LIST_SIZE

    def __init__(out self, max_table_size: Int):
        self.table = HpackDynamicTable(max_size=max_table_size)
        self.settings_table_size = max_table_size
        self.max_header_list_size = HPACK_DEFAULT_MAX_HEADER_LIST_SIZE

    def set_max_table_size(mut self, new_size: Int):
        """Record a new SETTINGS_HEADER_TABLE_SIZE advertised to the peer's
        encoder: `new_size` becomes the ceiling for size updates
        (`settings_table_size`) and the table's maximum, evicting entries
        that no longer fit. The on-wire size update may then set any
        maximum up to this ceiling (RFC 7541 §4.2).
        """
        self.settings_table_size = new_size
        self.table.set_max_size(new_size)

    def _lookup_indexed(self, hpack_index: Int) -> Tuple[String, String, Bool]:
        """Resolve an HPACK index to (name, value, ok)."""
        if hpack_index <= 0:
            return (String(""), String(""), False)
        if hpack_index <= HPACK_STATIC_TABLE_SIZE:
            var s = hpack_static_lookup(hpack_index)
            return (s[0], s[1], True)
        var dyn_idx = hpack_index - HPACK_STATIC_TABLE_SIZE - 1
        if dyn_idx < 0 or dyn_idx >= self.table.count():
            return (String(""), String(""), False)
        var d = self.table.lookup(dyn_idx)
        return (d[0], d[1], True)

    def decode_block(
        mut self,
        buf: Span[UInt8, _],
    ) raises -> List[HpackHeader]:
        """Decode an HPACK block. Raises on malformed input
        (COMPRESSION_ERROR-class conditions per RFC 7541).

        RFC 7541 §4.2 / RFC 9113 §4.3: Dynamic Table Size Update
        instructions MUST occur at the START of the header block, before
        any header fields. After the first non-update instruction, any
        subsequent size update is a COMPRESSION_ERROR.

        RFC 7541 §4.2 / §6.3: a size update's new maximum MUST be <= the
        SETTINGS_HEADER_TABLE_SIZE this decoder advertised
        (`settings_table_size`), whatever an earlier update set the table
        to, so an update may grow the table back after a shrink.
        """
        var out = List[HpackHeader]()
        var n = len(buf)
        var i = 0
        var seen_header_field = False
        # RFC 9113 §6.5.2 header-list-size budget for THIS block. Charged
        # ONCE per decoded representation at the bottom of the loop (not
        # per byte, not per use) — see the ceiling note at the tail.
        var header_list_size = 0
        var accounted = 0
        while i < n:
            var b0 = UInt32(Int(buf[i]))
            if (b0 & UInt32(0x80)) != UInt32(0):
                # Indexed (RFC 7541 §6.1): 1xxxxxxx.
                var ir = decode_integer(buf, i, 7)
                if not ir.ok:
                    raise Error("hpack: indexed truncated")
                var lk = self._lookup_indexed(Int(ir.value))
                if not lk[2]:
                    raise Error("hpack: invalid index")
                out.append(HpackHeader(
                    String(lk[0]), String(lk[1]),
                ))
                seen_header_field = True
                i = i + ir.consumed
            elif (b0 & UInt32(0xc0)) == UInt32(0x40):
                # Literal with incremental indexing (RFC 7541 §6.2.1):
                # 01xxxxxx
                var ir = decode_integer(buf, i, 6)
                if not ir.ok:
                    raise Error("hpack: literal-incremental idx truncated")
                var name_str = String()
                var nm_idx = Int(ir.value)
                i = i + ir.consumed
                if nm_idx == 0:
                    # Name literal follows.
                    var ns = decode_string(buf, i)
                    if not ns.ok:
                        raise Error("hpack: name string truncated")
                    swap(name_str, ns.value)
                    i = i + ns.consumed
                else:
                    var lk = self._lookup_indexed(nm_idx)
                    if not lk[2]:
                        raise Error("hpack: name index invalid")
                    name_str = lk[0]
                var vs = decode_string(buf, i)
                if not vs.ok:
                    raise Error("hpack: value string truncated")
                var value_str = String()
                swap(value_str, vs.value)
                i = i + vs.consumed
                # Add to dynamic table.
                var nm_copy = String(name_str)
                var val_copy = String(value_str)
                self.table.add(nm_copy^, val_copy^)
                out.append(HpackHeader(name_str^, value_str^))
                seen_header_field = True
            elif (b0 & UInt32(0xf0)) == UInt32(0x10):
                # Literal never-indexed (RFC 7541 §6.2.3): 0001xxxx.
                var ir = decode_integer(buf, i, 4)
                if not ir.ok:
                    raise Error("hpack: never-indexed idx truncated")
                var name_str = String()
                var nm_idx = Int(ir.value)
                i = i + ir.consumed
                if nm_idx == 0:
                    var ns = decode_string(buf, i)
                    if not ns.ok:
                        raise Error("hpack: name truncated")
                    swap(name_str, ns.value)
                    i = i + ns.consumed
                else:
                    var lk = self._lookup_indexed(nm_idx)
                    if not lk[2]:
                        raise Error("hpack: name index invalid")
                    name_str = lk[0]
                var vs = decode_string(buf, i)
                if not vs.ok:
                    raise Error("hpack: value truncated")
                var value_str = String()
                swap(value_str, vs.value)
                i = i + vs.consumed
                out.append(HpackHeader(name_str^, value_str^))
                seen_header_field = True
            elif (b0 & UInt32(0xf0)) == UInt32(0x00):
                # Literal no-indexing (RFC 7541 §6.2.2): 0000xxxx.
                var ir = decode_integer(buf, i, 4)
                if not ir.ok:
                    raise Error("hpack: no-index idx truncated")
                var name_str = String()
                var nm_idx = Int(ir.value)
                i = i + ir.consumed
                if nm_idx == 0:
                    var ns = decode_string(buf, i)
                    if not ns.ok:
                        raise Error("hpack: name truncated")
                    swap(name_str, ns.value)
                    i = i + ns.consumed
                else:
                    var lk = self._lookup_indexed(nm_idx)
                    if not lk[2]:
                        raise Error("hpack: name index invalid")
                    name_str = lk[0]
                var vs = decode_string(buf, i)
                if not vs.ok:
                    raise Error("hpack: value truncated")
                var value_str = String()
                swap(value_str, vs.value)
                i = i + vs.consumed
                out.append(HpackHeader(name_str^, value_str^))
                seen_header_field = True
            elif (b0 & UInt32(0xe0)) == UInt32(0x20):
                # Dynamic Table Size Update (RFC 7541 §6.3): 001xxxxx.
                # MUST appear before any header field per RFC 7541 §4.2.
                if seen_header_field:
                    raise Error(
                        "hpack: COMPRESSION_ERROR: size update after"
                        " header field"
                    )
                var ir = decode_integer(buf, i, 5)
                if not ir.ok:
                    raise Error(
                        "hpack: COMPRESSION_ERROR: size-update truncated"
                    )
                # RFC 7541 §6.3: "MUST be lower than or equal to the limit
                # determined by the protocol using HPACK", which RFC 9113
                # §6.5.2 makes SETTINGS_HEADER_TABLE_SIZE.
                if Int(ir.value) > self.settings_table_size:
                    raise Error(
                        "hpack: COMPRESSION_ERROR: size update above"
                        " SETTINGS_HEADER_TABLE_SIZE"
                    )
                self.table.set_max_size(Int(ir.value))
                i = i + ir.consumed
            else:
                raise Error("hpack: COMPRESSION_ERROR: unknown prefix")

            # ── HEADER-LIST CEILING ──
            # Charged ONCE per representation just decoded, against the
            # RFC 9113 §6.5.2 accounting unit. This is the amplification
            # stop: an INDEXED representation is ONE untrusted octet and
            # yields a full heap-owning (name, value) String pair, so an
            # unaccounted block mints ~1 header per input byte. Bounding it
            # here — at the point the list grows — costs one add + one
            # compare per header, never per byte and never per use.
            while accounted < len(out):
                header_list_size = (
                    header_list_size
                    + out[accounted].name.byte_length()
                    + out[accounted].value.byte_length()
                    + HPACK_HEADER_ENTRY_OVERHEAD
                )
                accounted = accounted + 1
            if header_list_size > self.max_header_list_size:
                raise Error(
                    "hpack: header list size "
                    + String(header_list_size)
                    + " octets exceeds the "
                    + String(self.max_header_list_size)
                    + "-octet SETTINGS_MAX_HEADER_LIST_SIZE budget after "
                    + String(len(out))
                    + " header fields (header-list flood?)"
                )
        return out^
