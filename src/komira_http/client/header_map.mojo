# =============================================================================
# src/komira_http/client/header_map.mojo — case-insensitive multi-value header map
# =============================================================================
#
#.3.F.2b HEADER STORAGE REDESIGN:
#   The OLD `SharedAlignedBuffer[alignment: Int]` (Copyable via ArcPointer
#   refcount-bump) has been retired. HeaderEntryView now holds a NEW
#   `HeaderBytes` value type — Copyable, Movable — that wraps
#   `ArcPointer[List[UInt8]] + offset + length`. Semantics are identical
#   to the prior shape:
#
#     * ONE allocation per response (a single `List[UInt8]` containing the
#       parsed header block bytes).
#     * N HeaderEntryViews share that allocation via ArcPointer refcount.
#     * Each view carries a (name_off, name_len, value_off, value_len)
#       quadruple computed by the parser; sub-views are virtual.
#     * Copy = Arc refcount inc (no byte copy).
#
#   The public API surface (`get_view`, `get_view_static`, `entry_at_view`,
#   `sab_to_string`, `parse_sab_int64`, `ci_byte_eq_sab_static`,
#   `entry_view.name`, `entry_view.value`) is preserved at the type-name
#   boundary: `Optional[SharedAlignedBuffer[64]]` → `Optional[HeaderBytes]`;
#   functions like `sab_to_string` retain their names + signatures rewritten
#   to take `HeaderBytes`. Downstream consumers (sigv4_layer, h2_client,
#   redirect, objectstore_http, s3) compile unchanged because they only
#   touch the helper free-functions + accessor field names.
#
# HEADERMAP-MEASUREMENT — PERF-CRITICAL:
#   the zero-copy / one-memcpy-per-response claim is LOAD-BEARING. The
#   parser allocates ONE `List[UInt8]` of size `headers_end + 4`, memcpy's
#   the head bytes once, wraps in `ArcPointer[List[UInt8]]`, then emits N
#   HeaderEntryViews each carrying an Arc clone (refcount inc, no bytes
#   copied). This is preserved unchanged from the SAB shape; only the
#   underlying primitive type changed.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature (HeaderBytes carries the bytes
#     via ArcPointer[List[UInt8]] — a fully-typed standard library value).
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ArcPointer[List[UInt8]] IS Copyable (Arc refcount inc); the wrapper
#     `HeaderBytes(Copyable, Movable)` is the same shape the OLD SAB was
#     ratified for (HTTP headers are the canonical shared-immutable-buffer
#     use case).
# =============================================================================

from std.collections.optional import Optional
from std.memory import ArcPointer


# =============================================================================
# §1 — HeaderBytes — Copyable byte-view over a refcounted backing List.
# =============================================================================
#
# Replaces the OLD `SharedAlignedBuffer[64]` for HTTP header storage. The
# core invariant is the same: N views may share ONE backing List via
# ArcPointer refcount; copy = refcount inc; drop = refcount dec; bytes
# freed on last drop.
#
# Why `List[UInt8]` (not `OwnedAlignedBuffer`): HTTP headers do not need
# 64-byte aligned access, SIMD, or Arrow-builder semantics. A plain
# `List[UInt8]` is the right primitive (one allocation, refcounted via
# ArcPointer); HeaderBytes carries only the (offset, length) sub-view
# into the backing List.


struct HeaderBytes(Copyable, Movable, Deinitable):
    """Refcounted byte-view backed by a shared `List[UInt8]`.

    Semantics mirror the prior `SharedAlignedBuffer[64]` used for header
    storage: copy = ArcPointer refcount inc (no byte copy); drop =
    refcount dec; backing storage freed on last drop. Multiple HeaderBytes
    can share the same backing List with different (offset, length)
    sub-views (zero-copy slicing).

    Fields:
        _inner: ArcPointer to the shared backing `List[UInt8]`. Refcount-
            managed; storage drops when refcount hits 0.
        offset: Byte offset into the backing List where this view starts.
        length: Number of bytes in this view (NOT the backing List's
            total length — the view may be a sub-slice). Public field for
            source-compat with the prior SAB.length access pattern used
            in test_header_map.mojo:133.
    """

    var _inner: ArcPointer[List[UInt8]]
    var offset: Int
    var length: Int

    def __init__(out self, var bytes: List[UInt8]):
        """Wrap a freshly-owned `List[UInt8]` in shared ownership.

        Args:
            bytes: Consumed; ownership transferred into the ArcPointer.
        """
        var byte_count = len(bytes)
        self._inner = ArcPointer[List[UInt8]](bytes^)
        self.offset = 0
        self.length = byte_count

    def __init__(
        out self,
        inner: ArcPointer[List[UInt8]],
        offset: Int,
        length: Int,
    ):
        """File-internal: build a sub-view from an existing ArcPointer +
        (offset, length). Used by `slice` to construct a sub-view that
        shares storage with the source.

        Args:
            inner: ArcPointer to the shared backing List. Refcount inc'd
                on copy.
            offset: Byte offset into the backing List.
            length: Byte length of this sub-view.
        """
        self._inner = inner
        self.offset = offset
        self.length = length

    def __init__(out self, *, copy: Self):
        """Explicit copy ctor — ArcPointer is Copyable via refcount-inc."""
        self._inner = copy._inner
        self.offset = copy.offset
        self.length = copy.length

    def copy(self) -> Self:
        """Return an Arc-clone of self (refcount inc, no byte copy).

        Mirror of OLD `SharedAlignedBuffer.copy()`. Used by `get_view` /
        `get_view_static` / `entry_at_view` egress paths that need to
        return an owned HeaderBytes from the stored entry.
        """
        return Self(copy=self)

    def slice(self, byte_offset: Int, byte_length: Int) raises -> Self:
        """Create a zero-copy sub-view. Both this and the returned view
        share the same backing List via ArcPointer refcount.

        Args:
            byte_offset: Starting byte offset relative to THIS view's start.
            byte_length: Number of bytes in the sub-view.

        Returns:
            A HeaderBytes viewing `[offset + byte_offset, ... + byte_length)`
            within the shared backing.

        Raises:
            Error if the slice range is out of bounds.
        """
        if (
            byte_offset < 0
            or byte_length < 0
            or byte_offset + byte_length > self.length
        ):
            raise Error(
                "HeaderBytes.slice: range ["
                + String(byte_offset)
                + ", "
                + String(byte_offset + byte_length)
                + ") out of bounds [0, "
                + String(self.length)
                + ")"
            )
        return Self(self._inner, self.offset + byte_offset, byte_length)

    @always_inline
    def unsafe_get(self, byte_index: Int) -> UInt8:
        """Read a single byte at `byte_index` relative to this view.

        No bounds checking. Caller must ensure `byte_index < self.length`.
        """
        return self._inner[][self.offset + byte_index]

    @always_inline
    def __len__(self) -> Int:
        """Number of usable bytes in this view (Sized conformance)."""
        return self.length


# =============================================================================
# §2 — HeaderEntryView (Copyable so List[HeaderEntryView] is well-typed).
# =============================================================================
#
# Each entry holds TWO HeaderBytes — name + value — that typically point
# into the SAME backing List (the per-response head buffer). Stored as
# separate HeaderBytes (rather than offsets-into-a-third-Arc) for symmetry
# with the prior SAB shape and to keep the public field names (`.name`,
# `.value`) stable across the migration.


struct HeaderEntryView(Copyable, Movable, Deinitable):
    """One header entry as a pair of zero-copy byte views.

    Both fields are `HeaderBytes` (Copyable via ArcPointer refcount-inc).
    The underlying bytes typically live in a single per-response head
    backing List that both fields share. Comparison in `get` / `contains`
    walks bytes via `unsafe_get` on the HeaderBytes (no String alloc).

    Names are NOT pre-lowercased — the parser writes whatever the wire
    delivered. Case-insensitive matching is done at lookup time via
    `_ci_byte_eq_name`.

    Explicit copy + move ctors retained because HeaderBytes is Copyable
    but the generic `@fieldwise_init` synthesis is cautious about
    Arc-bearing fields.
    """

    var name: HeaderBytes
    """Header name bytes (raw casing, as on the wire)."""

    var value: HeaderBytes
    """Header value bytes (no leading/trailing OWS — parser strips)."""

    def __init__(out self, var name: HeaderBytes, var value: HeaderBytes):
        self.name = name^
        self.value = value^

    def __init__(out self, *, copy: Self):
        """Copy ctor — HeaderBytes is Copyable via ArcPointer
        refcount-inc. Both sub-views are Arc-cloned."""
        self.name = copy.name.copy()
        self.value = copy.value.copy()


# =============================================================================
# §3 — HeaderEntry (Copyable String-based view for back-compat egress).
# =============================================================================
#
# Returned by `entries()` and `entry_at()`. Egress consumers still
# expect String-typed fields; we materialize per-call from the HeaderBytes
# storage. This is the back-compat shim that this module keeps stable.


@fieldwise_init
struct HeaderEntry(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One header entry: case-folded name + raw value, materialized as
    Strings for egress consumers."""

    var name: String
    """ASCII-lowercased name."""

    var value: String
    """Header value bytes copied to String."""


# =============================================================================
# §4 — Helpers.
# =============================================================================


@always_inline
def _to_lower_ascii(b: UInt8) -> UInt8:
    var c = Int(b)
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return UInt8(c + 32)
    return b


def _sab_to_string(hb: HeaderBytes) -> String:
    """Materialize a HeaderBytes's bytes into a fresh String.

    Per-byte loop; for typical HTTP header sizes (10-30 bytes) this is
    not measurably slower than `String(StringSlice(unsafe_from_utf8=...))`
    round-tripped through SSO-encode.
    """
    var out = String()
    var n = hb.length
    var i = 0
    while i < n:
        out = out + chr(Int(hb.unsafe_get(i)))
        i = i + 1
    return out^


def _sab_to_string_lower(hb: HeaderBytes) -> String:
    """Materialize HeaderBytes into a lowercase String."""
    var out = String()
    var n = hb.length
    var i = 0
    while i < n:
        out = out + chr(Int(_to_lower_ascii(hb.unsafe_get(i))))
        i = i + 1
    return out^


@always_inline
def _ci_byte_eq_sab_string(hb: HeaderBytes, probe: String) -> Bool:
    """Case-insensitive byte equality between a HeaderBytes and a String
    probe. Used by get/contains/_index_of to match a wire name against
    the caller's lookup name without allocating a canonical String per
    entry."""
    var probe_bytes = probe.as_bytes()
    var n = hb.length
    if n != len(probe_bytes):
        return False
    var i = 0
    while i < n:
        var a = _to_lower_ascii(hb.unsafe_get(i))
        var b = _to_lower_ascii(probe_bytes[i])
        if a != b:
            return False
        i = i + 1
    return True


@always_inline
def ci_byte_eq_sab_static(hb: HeaderBytes, probe: StaticString) -> Bool:
    """Case-insensitive byte equality between a HeaderBytes and a
    StaticString probe. Public helper used by sigv4_layer + h2_client to
    byte-compare entry-iteration names against literal skip-lists
    ("host", "authorization", ...) without materializing either side into
    a per-iter String."""
    var probe_bytes = probe.as_bytes()
    var n = hb.length
    if n != len(probe_bytes):
        return False
    var i = 0
    while i < n:
        var a = _to_lower_ascii(hb.unsafe_get(i))
        var b = _to_lower_ascii(probe_bytes[i])
        if a != b:
            return False
        i = i + 1
    return True


# ---- Public exports: HeaderBytes materialization helpers ------------------


def sab_to_string(hb: HeaderBytes) -> String:
    """Materialize a HeaderBytes's bytes into a fresh String. Public
    re-export for egress consumers (objectstore_http / redirect / s3)
    that need a String at the call-site boundary.

    Name preserved from the SAB era for source-compat with the 5 external
    HTTP-client consumers (sigv4_layer / h2_client / redirect /
    objectstore_http / s3); the underlying primitive flipped from SAB to
    HeaderBytes in.3.F.2b but the helper's name + signature shape are
    intentionally unchanged.
    """
    return _sab_to_string(hb)


def sab_to_string_lower(hb: HeaderBytes) -> String:
    """Materialize a HeaderBytes's bytes into a lowercased String."""
    return _sab_to_string_lower(hb)


@always_inline
def parse_sab_int64(hb: HeaderBytes) -> Optional[Int64]:
    """Parse a non-negative Int64 from a HeaderBytes's bytes without
    going through String. Used for Content-Length lookups in
    objectstore_http + s3 — the hottest String-materialization site
    after sigv4.

    Returns Some(value) on a valid decimal-digit run; None on empty,
    leading whitespace, or any non-digit. Used by `get_int64(name)`."""
    var n = hb.length
    if n == 0:
        return Optional[Int64]()
    var acc: Int64 = 0
    var i = 0
    while i < n:
        var b = hb.unsafe_get(i)
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return Optional[Int64]()
        acc = acc * Int64(10) + Int64(Int(b) - Int(ord("0")))
        i = i + 1
    return Optional[Int64](acc)


# =============================================================================
# §5 — HeaderMap.
# =============================================================================


struct HeaderMap(Movable, Deinitable):
    """Case-insensitive multi-value header map.

    Storage is `List[HeaderEntryView]` (two HeaderBytes per entry). The
    response parser populates entries via `append_view` against a per-
    response head ArcPointer[List[UInt8]]. Back-compat callers
    (sts_retry / creds / request_writer / tests) use
    `insert(String, String)` / `append(String, String)` which build a
    small per-entry backing List.

    Public API surface preserved from the SAB era:
      insert / append / get / get_all / contains / remove / len /
      entries / entry_at / clear / entry_at_view / get_view /
      get_view_static / get_int64 / contains_static.
    """

    var _entries: List[HeaderEntryView]

    def __init__(out self):
        self._entries = List[HeaderEntryView]()

    @always_inline
    def len(self) -> Int:
        """Total entry count (not unique names)."""
        return self._entries.__len__()

    @always_inline
    def is_empty(self) -> Bool:
        return self._entries.__len__() == 0

    # ---- Back-compat insert / append (String inputs) ---------------------

    def insert(mut self, var name: String, var value: String) raises:
        """Insert `name: value`, REPLACING all existing entries for
        `name`. Back-compat shim for non-parser callers."""
        self._remove_all_ci(name)
        var view = self._build_entry_from_strings(name, value)
        self._entries.append(view^)

    def append(mut self, var name: String, var value: String) raises:
        """Append `name: value`, KEEPING all existing entries for
        `name`. Back-compat shim for non-parser callers."""
        var view = self._build_entry_from_strings(name, value)
        self._entries.append(view^)

    # ---- Parser fast path (zero-copy slice of the head backing) ----------

    def append_view(
        mut self,
        head_bytes: HeaderBytes,
        name_off: Int,
        name_len: Int,
        value_off: Int,
        value_len: Int,
    ) raises:
        """Fast path: build a header entry as two sub-slices of the
        per-response head HeaderBytes. NO byte copy; ArcPointer refcount
        bump × 2 (one per sub-slice).

        The parser is the only intended caller. Called once per parsed
        header line during `parse_response_head`.
        """
        var name_hb = head_bytes.slice(name_off, name_len)
        var value_hb = head_bytes.slice(value_off, value_len)
        self._entries.append(HeaderEntryView(name=name_hb^, value=value_hb^))

    # ---- Lookup ----------------------------------------------------------

    def get_view(self, name: String) -> Optional[HeaderBytes]:
        """Return the FIRST value matching `name` as a HeaderBytes clone
        (Arc-bump, NO byte copy), or None. Case-insensitive on the name."""
        var n = self._entries.__len__()
        var i = 0
        while i < n:
            if _ci_byte_eq_sab_string(self._entries[i].name, name):
                return Optional[HeaderBytes](self._entries[i].value.copy())
            i = i + 1
        return Optional[HeaderBytes]()

    def get_view_static(self, name: StaticString) -> Optional[HeaderBytes]:
        """`get_view` against a compile-time-known name literal — no
        per-call String allocation for the lookup key."""
        var n = self._entries.__len__()
        var i = 0
        while i < n:
            if ci_byte_eq_sab_static(self._entries[i].name, name):
                return Optional[HeaderBytes](self._entries[i].value.copy())
            i = i + 1
        return Optional[HeaderBytes]()

    def get(self, name: String) -> Optional[String]:
        """Return the FIRST value matching `name` as a fresh String, or
        None. Case-insensitive. BOUNDARY shim: pays one String
        materialization."""
        var n = self._entries.__len__()
        var i = 0
        while i < n:
            if _ci_byte_eq_sab_string(self._entries[i].name, name):
                return Optional[String](_sab_to_string(self._entries[i].value))
            i = i + 1
        return Optional[String]()

    def get_int64(self, name: String) -> Optional[Int64]:
        """Parse the FIRST value matching `name` as a non-negative Int64
        directly from the value bytes — NO String materialization.
        Returns None on missing header, non-digit content, or empty
        value."""
        var n = self._entries.__len__()
        var i = 0
        while i < n:
            if _ci_byte_eq_sab_string(self._entries[i].name, name):
                return parse_sab_int64(self._entries[i].value)
            i = i + 1
        return Optional[Int64]()

    def get_all(self, name: String) -> List[String]:
        """Return ALL values matching `name`, in insertion order."""
        var n = self._entries.__len__()
        var out = List[String]()
        var i = 0
        while i < n:
            if _ci_byte_eq_sab_string(self._entries[i].name, name):
                out.append(_sab_to_string(self._entries[i].value))
            i = i + 1
        return out^

    @always_inline
    def contains(self, name: String) -> Bool:
        """True iff at least one entry matches `name` (case-insensitive)."""
        var n = self._entries.__len__()
        var i = 0
        while i < n:
            if _ci_byte_eq_sab_string(self._entries[i].name, name):
                return True
            i = i + 1
        return False

    @always_inline
    def contains_static(self, name: StaticString) -> Bool:
        """`contains` against a compile-time-known name — no per-call
        String allocation."""
        var n = self._entries.__len__()
        var i = 0
        while i < n:
            if ci_byte_eq_sab_static(self._entries[i].name, name):
                return True
            i = i + 1
        return False

    def remove(mut self, name: String):
        """Remove ALL entries for `name`."""
        self._remove_all_ci(name)

    def entries(self) -> List[HeaderEntry]:
        """Return a copy of the entries (insertion order). Materializes
        each entry into String name + String value — boundary path for
        consumers that need a full pre-materialized snapshot.

        Hot-path consumers should use `len()` + `entry_at_view(i)` —
        walk the HeaderBytes views, byte-compare names, and only
        materialize Strings on the keep-path.
        """
        var n = self._entries.__len__()
        var out = List[HeaderEntry]()
        var i = 0
        while i < n:
            out.append(HeaderEntry(
                name=_sab_to_string_lower(self._entries[i].name),
                value=_sab_to_string(self._entries[i].value),
            ))
            i = i + 1
        return out^

    @always_inline
    def entry_at_view(self, idx: Int) -> HeaderEntryView:
        """Random-access by index, returning the HeaderBytes-backed view
        (Arc-clone, no byte copy)."""
        return HeaderEntryView(copy=self._entries[idx])

    @always_inline
    def entry_at(self, idx: Int) -> HeaderEntry:
        """Random-access by index. Materializes one HeaderEntry."""
        return HeaderEntry(
            name=_sab_to_string_lower(self._entries[idx].name),
            value=_sab_to_string(self._entries[idx].value),
        )

    def clear(mut self):
        """Remove every entry."""
        self._entries.clear()

    # ---- Internal helpers ------------------------------------------------

    def _build_entry_from_strings(
        self, name: String, value: String
    ) raises -> HeaderEntryView:
        """Back-compat constructor: build a small per-entry List
        containing the name + value bytes contiguously, then slice
        twice. NOT in any hot path — only invoked by non-parser
        callers (sts_retry / creds / request_writer / tests)."""
        var name_bytes = name.as_bytes()
        var value_bytes = value.as_bytes()
        var name_len = len(name_bytes)
        var value_len = len(value_bytes)
        var total = name_len + value_len
        # Build a fresh List[UInt8] of size `total`. For total == 0 we
        # still build a 1-element placeholder so the ArcPointer's backing
        # is non-empty; the sub-views are 0-length and never read it.
        var alloc_size = total if total > 0 else 1
        var bytes = List[UInt8]()
        bytes.reserve(alloc_size)
        var i = 0
        while i < name_len:
            bytes.append(name_bytes[i])
            i = i + 1
        var j = 0
        while j < value_len:
            bytes.append(value_bytes[j])
            j = j + 1
        if total == 0:
            bytes.append(UInt8(0))  # placeholder for the empty-empty case
        # Wrap the populated List in HeaderBytes (ArcPointer adoption),
        # then carve out the two sub-views.
        var head = HeaderBytes(bytes^)
        var name_hb = head.slice(0, name_len)
        var value_hb = head.slice(name_len, value_len)
        return HeaderEntryView(name=name_hb^, value=value_hb^)

    def _remove_all_ci(mut self, name: String):
        """Remove every entry whose name matches `name` case-insensitively."""
        var n = self._entries.__len__()
        if n == 0:
            return
        var kept = List[HeaderEntryView]()
        var i = 0
        while i < n:
            if not _ci_byte_eq_sab_string(self._entries[i].name, name):
                kept.append(HeaderEntryView(copy=self._entries[i]))
            i = i + 1
        self._entries = kept^
