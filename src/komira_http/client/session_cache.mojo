# =============================================================================
# src/komira_http/client/session_cache.mojo — TLS session-resumption cache
# =============================================================================
#
# Per-PoolKey storage of TLS
# session-ticket blobs the client can replay on a subsequent connect to the
# same origin to skip the full handshake (saves ~1 round-trip).
#
# SessionCache: per-PoolKey
# lookup + store; LRU eviction; bounded size knob in PoolSizingKnobs.
# Architecture:
#
#   * Per-pthread, single-thread-access — mirrors PerCorePool's
#     architecture. NO atomics, NO locks. A sharded shared variant is
#     a separate shape.
#   * Storage: `Slab[_SessionCacheEntry]` (pointer-safe
#     pattern). _SessionCacheEntry has only POD + List[UInt8] leaf-heap
#     fields — no inner heap-owning T to defeat lifetime tracking.
#   * Eviction: LRU. On store-when-full, linear-scan for oldest
#     `_last_used_us` + swap_remove. With default cap 1024 the linear
#     scan is hot-path-invisible vs ms-scale TLS handshake.
#   * Lookup: linear scan with `hash_u64` short-circuit. Same shape as
#     PerCorePool's `_find_bucket_idx`.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee` (Slab handles the partial-move primitives).
#   * ZERO new ArcPointer.
#   * ZERO additive parallel API — SessionCacheStub is REPLACED, not
#     paralleled.
#
# Pointer audit:
#   * `_SessionCacheEntry` has `PoolKey` (Copyable, String + 5 PODs),
#     `List[UInt8]` (leaf heap; no inner T), `Int` (POD). NONE of these
#     fields are stale-pointer hazard.
#   * Stored in `Slab[_SessionCacheEntry]` directly (no OwnedPointer
#     wrap needed — `_SessionCacheEntry` is Movable + Copyable-free at
#     our usage shape; the Slab takes ownership on append + drops via
#     destroy_pointee on drop).
# =============================================================================

from std.memory import OwnedPointer

from komira_core.collections.slab import Slab

from komira_http.client.pool import PoolKey


# =============================================================================
# §1 — Default cache size
# =============================================================================
#
# Default max_session_cache_entries. Plumbed via PoolSizingKnobs; this is
# the fallback when no per-pool override is set. 1024 matches Chrome's
# typical client cache size and is comfortably under the linear-scan cost
# threshold (1024 entries * ~10ns per compare = ~10us; TLS handshake is
# milliseconds, so cache lookup overhead is < 1% of handshake wall time
# even on cache-miss).

comptime DEFAULT_MAX_SESSION_CACHE_ENTRIES: Int = 1024
"""Default cap on per-pthread session cache entries. Beyond this, LRU
eviction kicks in on the next store. Tune via
PoolSizingKnobs.max_session_cache_entries at SessionCache construction."""


# =============================================================================
# §2 — _SessionCacheEntry — one cached ticket
# =============================================================================
#
# Per-entry record. Movable, NOT Copyable (List[UInt8] could be made
# Copyable but copying tickets across cache slots would waste memory; the
# Slab moves entries via init_pointee_move on append + take_pointee on
# eviction — no copy needed).
#
# Fields:
#   _key           — the PoolKey this ticket is for. Copyable; safe to
#                    pass by value during lookups.
#   _blob          — the serialized TLS session state s2n produced via
#                    `s2n_connection_get_session`. Opaque bytes; we never
#                    interpret. List[UInt8] is leaf-heap (no inner T) so
#                    pointer-safe inside the Slab.
#   _last_used_us  — monotonic timestamp set by lookup-hit + store. The
#                    LRU eviction picks the entry with the smallest value.


struct _SessionCacheEntry(Movable, Deinitable):
    """One cached TLS session-ticket blob, keyed by PoolKey.

    Movable, NOT Copyable. The Slab takes ownership on append + moves on
    eviction; never duplicates entries.
    """

    var _key: PoolKey
    var _blob: List[UInt8]
    var _last_used_us: Int

    def __init__(
        out self,
        var _key: PoolKey,
        var _blob: List[UInt8],
        _last_used_us: Int,
    ):
        self._key = _key^
        self._blob = _blob^
        self._last_used_us = _last_used_us

    def key(self) -> PoolKey:
        return self._key.copy()

    def last_used_us(self) -> Int:
        return self._last_used_us

    def blob_len(self) -> Int:
        return len(self._blob)


# =============================================================================
# §3 — SessionCache — per-PoolKey LRU bounded ticket cache
# =============================================================================
#
# Public surface:
#   * `SessionCache.new(max_entries)` — construct with capacity bound.
#   * `SessionCache.with_defaults()` — convenience, uses
#     DEFAULT_MAX_SESSION_CACHE_ENTRIES.
#   * `lookup(key, now_us) -> Optional[List[UInt8]]` — returns a COPY of
#     the cached blob if present, None if absent. Bumps the entry's
#     last_used_us on hit (LRU bookkeeping).
#   * `store(var key, var blob, now_us)` — insert or replace. On
#     replace, the existing entry is updated in place (same slot, new
#     blob + new last_used). On insert when full, evict the LRU entry.
#   * `evict_one(now_us) -> Bool` — explicit eviction for tests.
#   * `len() -> Int` / `capacity() -> Int` — diagnostics.
#   * `contains(key) -> Bool` — diagnostic (no last_used bump).
#
# Movable, NOT Copyable (Slab is non-Copyable). One instance per pthread;
# the parent TlsConnector owns the cache as a struct field.


struct SessionCache(Movable, Deinitable):
    """Per-pthread TLS session-ticket cache, keyed by PoolKey, LRU
    eviction at bounded capacity.

    Construction:
      * `SessionCache.new(max_entries)` — explicit capacity bound.
      * `SessionCache.with_defaults()` — uses
        DEFAULT_MAX_SESSION_CACHE_ENTRIES (1024).

    Concurrency: single-thread-access (per-pthread). Mirrors PerCorePool's
    architecture exactly — no atomics, no locks. Multi-thread sharing
    is the SharedPool concern.

    Lookup hits return a COPY of the blob bytes (the cache retains the
    original). This is intentional: the caller passes the copy to
    `TlsConnection.set_session` which consumes the bytes via FFI; the
    cache's original is preserved for subsequent lookups (resumption is
    not single-use — the same ticket can resume multiple sessions until
    its TTL expires server-side).

    Fields:
      _entries     — Slab of cache entries (pointer-safe storage).
      _max_entries — bounded capacity; LRU eviction kicks in at this size.
    """

    var _entries: Slab[_SessionCacheEntry]
    var _max_entries: Int

    @staticmethod
    def new(max_entries: Int) -> SessionCache:
        """Construct a session cache with explicit capacity bound.
        `max_entries` MUST be >= 1; smaller values are clamped to 1.
        """
        var cap = max_entries
        if cap < 1:
            cap = 1
        return SessionCache(
            _entries=Slab[_SessionCacheEntry](),
            _max_entries=cap,
        )

    @staticmethod
    def with_defaults() -> SessionCache:
        """Convenience: construct with DEFAULT_MAX_SESSION_CACHE_ENTRIES
        (1024)."""
        return SessionCache.new(DEFAULT_MAX_SESSION_CACHE_ENTRIES)

    def __init__(
        out self,
        var _entries: Slab[_SessionCacheEntry],
        _max_entries: Int,
    ):
        self._entries = _entries^
        self._max_entries = _max_entries

    # ----- Diagnostics -------------------------------------------------------

    def len(self) -> Int:
        """Number of entries currently cached."""
        return self._entries.len()

    def capacity(self) -> Int:
        """Max entries before LRU eviction kicks in."""
        return self._max_entries

    def contains(self, key: PoolKey) -> Bool:
        """Diagnostic: True if `key` has a cached entry. Does NOT bump
        last_used_us (lookup is the LRU-touch path)."""
        return self._find_idx(key) >= 0

    # ----- Internal: linear scan ---------------------------------------------

    def _find_idx(self, key: PoolKey) -> Int:
        """Linear-scan index lookup. Returns -1 if no entry matches.

        Same shape as PerCorePool._find_bucket_idx; hash_u64 is a
        fast-path discriminator but PoolKey.__eq__ is the source of truth
        (covers the rare hash collision).
        """
        var n = self._entries.len()
        var target_hash = key.hash_u64()
        var i = 0
        while i < n:
            # Hash-prefilter avoids the String byte-compare on misses.
            var entry_key = self._entries[i].key()
            if entry_key.hash_u64() == target_hash:
                if entry_key == key:
                    return i
            i = i + 1
        return -1

    def _find_lru_idx(self) -> Int:
        """Linear-scan for the index of the entry with the smallest
        last_used_us (the LRU victim). Returns -1 if cache is empty.
        """
        var n = self._entries.len()
        if n == 0:
            return -1
        var oldest_idx = 0
        var oldest_us = self._entries[0].last_used_us()
        var i = 1
        while i < n:
            var u = self._entries[i].last_used_us()
            if u < oldest_us:
                oldest_us = u
                oldest_idx = i
            i = i + 1
        return oldest_idx

    # ----- Public surface ----------------------------------------------------

    def lookup(
        mut self, key: PoolKey, now_us: Int,
    ) raises -> Optional[List[UInt8]]:
        """Return a COPY of the cached ticket blob for `key`, or None if
        absent. On hit, bumps `last_used_us` to `now_us` (LRU touch).

        Why a copy: the caller passes the bytes to s2n via
        `TlsConnection.set_session` which consumes them. The cache must
        retain the original for subsequent lookups (session tickets are
        not single-use until expiry).
        """
        var idx = self._find_idx(key)
        if idx < 0:
            return Optional[List[UInt8]]()
        # Hit: bump last_used + copy out blob bytes.
        # We use the Slab's `replace` primitive to update the entry
        # in-place without partial-move tripping the borrow checker.
        var prev = self._entries.replace(
            idx,
            _SessionCacheEntry(
                _key=self._entries[idx].key(),
                _blob=self._entries[idx]._blob.copy(),
                _last_used_us=now_us,
            ),
        )
        # prev holds the old entry; we copy its blob OUT before dropping.
        var blob_copy = prev._blob.copy()
        _ = prev^  # drop the old entry; the new one (with bumped
                   # last_used) is now at idx.
        return Optional[List[UInt8]](blob_copy^)

    def store(
        mut self,
        var key: PoolKey,
        var blob: List[UInt8],
        now_us: Int,
    ) raises:
        """Insert or replace the cached ticket for `key`. The cache takes
        ownership of `blob`.

        Semantics:
          * If `key` already has an entry, REPLACE in place (same slot,
            new blob, last_used bumped to now_us). Old blob is dropped.
          * Else if `len() < max_entries`, append a new entry.
          * Else evict the LRU entry, then append.

        Idempotent re-store: passing the same blob twice for the same key
        is a no-op-with-bumped-last_used. Empty blobs are NOT stored
        (raises Error).
        """
        if len(blob) == 0:
            raise Error("SessionCache.store: empty blob")
        var idx = self._find_idx(key)
        if idx >= 0:
            # Replace in place. Drop the old entry's blob; install the
            # new one. Same slot — preserves LRU position semantics
            # (it's now the most-recent entry by last_used).
            var _old = self._entries.replace(
                idx,
                _SessionCacheEntry(
                    _key=key^, _blob=blob^, _last_used_us=now_us,
                ),
            )
            _ = _old^
            return
        # Insert path.
        if self._entries.len() >= self._max_entries:
            # Evict LRU before append.
            var victim_idx = self._find_lru_idx()
            if victim_idx >= 0:
                var _evicted = self._entries.swap_remove(victim_idx)
                _ = _evicted^
        self._entries.append(
            _SessionCacheEntry(
                _key=key^, _blob=blob^, _last_used_us=now_us,
            ),
        )

    def evict_one(mut self, now_us: Int) -> Bool:
        """Evict the LRU entry. Returns True if an entry was removed,
        False if cache is empty.

        `now_us` reserved for future per-TTL eviction (a follow-up could
        evict any entry whose age exceeds a configured threshold); for
        the timestamp is consulted indirectly via the LRU lookup
        only.
        """
        _ = now_us
        var idx = self._find_lru_idx()
        if idx < 0:
            return False
        var _evicted = self._entries.swap_remove(idx)
        _ = _evicted^
        return True

    def clear(mut self):
        """Drop all cached entries. The Slab drops each entry via its
        normal destructor."""
        # Pop until empty. Slab's pop returns the entry, which then
        # drops via __del__.
        while self._entries.len() > 0:
            var maybe = self._entries.pop()
            if maybe.__bool__():
                var entry = maybe.take()
                _ = entry^
            else:
                break
