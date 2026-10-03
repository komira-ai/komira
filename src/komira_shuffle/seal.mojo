# =============================================================================
# komira_shuffle/seal.mojo
#   The `StepComplete` SEAL body codec for the distributed shuffle.
# =============================================================================
#
# THE COMPLETION SEAL — the keystone. This is the SOLE read barrier: the
# single CAS-linearized
# "this step is closed, this EXACT producer set committed each-once" fact a
# reducer blocks on. It carries:
#   * `expected_producers` / `committed_producers` — verified as SETS, each-once
#     (a count is the wrong invariant: it double-reads under the map replay
#     fault-tolerance requires).
#   * the DENSE per-partition read plan, CAPPED: `index_mode == LIFTED` carries
#     the full plan;
#     `index_mode == TRAILER_FALLBACK` carries only the verified set + object
#     keys + the `[entries_floor, entries_ceiling)` window, and the consumer
#     tail-GETs each `.seg` trailer.
#
# ============================ DECISION (b) ===================================
# The seal-write rides `append_idempotent`
# under a RESERVED writer id (`SEAL_WRITER`). Its `DedupSentinel` create-CAS is
# the linearization point (it arbitrates a genuine concurrent double-drive). We
# treat the `_seal` prefix as a SINGLE-SLOT store: a present chunk IS the seal.
#
# SUBSTRATE-HONEST REFINEMENT (verified against cas_manifest's code, not its
# docstring): "rely on the sentinel happy path to return DUPLICATE on re-drive"
# does NOT hold as-is against the real protocol. `append_idempotent`'s
# recovery-to-DUPLICATE requires EITHER `_FINALIZE_ON_HOT_PATH` (OFF by default,
# cas_manifest.mojo) OR a chunk body whose `_body_matches_producer_batch`
# tail-scan can match (cas_manifest.mojo) — and that matcher REJECTS any
# `producer_id < 0` AND expects the broker producer trailer in
# the body, which DECISION (b) forbids embedding (no cross-package coupling). So
# a staged-then-re-driven seal append returns RETRYABLE, not DUPLICATE. The
# driver therefore makes the seal's PRESENCE the idempotency oracle: it
# pre-checks `read_head_authoritative()` on the `_seal` prefix and returns the
# EXISTING decoded seal on a re-drive (no re-append). This realizes the
# single-slot intent against the real substrate. It is safe because the
# driver-join is single-writer-per-step (head-cache safety) and a re-driven
# step recomputes the BYTE-IDENTICAL seal from the same
# durable `_entries` (the seal content is DETERMINISTIC — same expected/committed
# sets, same dense read plan), so the reducer's `read_chunk(top)` is correct
# regardless of which copy it lands on. We do NOT embed the broker producer
# trailer in the seal body. The append uses `producer_id = SEAL_WRITER`,
# `producer_epoch = 0`, `registered_epoch = 0` (so `producer_epoch <
# registered_epoch` is FALSE -> the seal is NEVER fenced), `first_seq ==
# last_seq == step_id`. The full pre-check + RETRYABLE-re-read logic lives in
# `seal_driver.seal_step`.
# =============================================================================
#
# Pointer discipline: ZERO UnsafePointer. `StepComplete` is a transient value
# (Copyable/Movable; its `List`/`String` fields are owned-heap, but it is never
# a byte-slab element, never a long-lived or wildcard-origin field) ->
# heap-reuse N/A. The struct exists only on the stack during encode/decode + the
# seal append/read.
# =============================================================================

from komira_shuffle.codec import (
    put_i64_le,
    get_i64_le,
    put_i64_list,
    get_i64_list,
    put_str_list,
    get_str_list,
)


# -----------------------------------------------------------------------------
# Reserved seal-writer identity + the index-mode discriminator + the wire magic.
# -----------------------------------------------------------------------------

# DECISION (b): the reserved writer id the driver passes to `append_idempotent`
# for the `_seal` prefix. A large negative sentinel that no real producer_id
# (>= 0, plan-assigned) can collide with -> the seal sentinel `(SEAL_WRITER,
# step_id)` is unique to the seal write.
comptime SEAL_WRITER: Int64 = Int64(-9_000_000_000_000_000_000)

# index_mode discriminator.
comptime SEAL_INDEX_LIFTED: UInt8 = UInt8(0)
comptime SEAL_INDEX_TRAILER_FALLBACK: UInt8 = UInt8(1)

# Wire magic prefixing every encoded seal body (truncation/format sentinel).
comptime _SEAL_MAGIC: Int64 = Int64(0x5345_414C_5354_4550)  # "SEALSTEP"


@fieldwise_init
struct StepComplete(Copyable, Movable, Deinitable):
    """The seal body — the linearized "this step is closed, this exact set
    committed each-once" fact.

    All producer-id Lists are kept SORTED so equality is order-stable and the
    encode is deterministic (DECISION (b) byte-identical-duplicate property).

    The dense read plan (LIFTED mode) is stored as three parallel lists:
      * `read_plan_producer_ids[i]`  — producer id of plan row i
      * `read_plan_object_keys[i]`   — that producer's `.seg` key
      * `read_plan_index`            — P*R*3 dense i64s, row-major over
                                       (producer i, partition p): for plan row i,
                                       partition p occupies
                                       `read_plan_index[(i*R + p)*3 + {0,1,2}]`
                                       = (offset, len, row_count). EXACTLY R
                                       entries per producer, INCLUDING zero-length
                                       (the DENSE-INDEX INVARIANT).

    TRAILER_FALLBACK mode leaves the read-plan lists EMPTY and instead relies on
    `entries_floor`/`entries_ceiling` (the `[log_start, seal_slot)` window over
    `_entries`) so the consumer tail-GETs each `.seg` trailer over the verified
    set. The seal driver writes LIFTED; the codec round-trips BOTH.

    Field layout:
      var shuffle_id: Int64
      var step_id: Int64
      var partition_count: Int64                  — R
      var index_mode: UInt8                        — LIFTED | TRAILER_FALLBACK
      var expected_producers: List[Int64]          — SORTED, the plan-fixed set
      var committed_producers: List[Int64]         — SORTED, the deduped set
      var read_plan_producer_ids: List[Int64]      — LIFTED only
      var read_plan_object_keys: List[String]      — LIFTED only
      var read_plan_index: List[Int64]             — LIFTED only, P*R*3 dense
      var entries_floor: Int64                     — TRAILER_FALLBACK window lo
      var entries_ceiling: Int64                   — TRAILER_FALLBACK window hi
    """

    var shuffle_id: Int64
    var step_id: Int64
    var partition_count: Int64
    var index_mode: UInt8
    var expected_producers: List[Int64]
    var committed_producers: List[Int64]
    var read_plan_producer_ids: List[Int64]
    var read_plan_object_keys: List[String]
    var read_plan_index: List[Int64]
    var entries_floor: Int64
    var entries_ceiling: Int64

    @always_inline
    def is_lifted(self) -> Bool:
        return self.index_mode == SEAL_INDEX_LIFTED

    def dense_slot(
        self, plan_row: Int, partition: Int
    ) raises -> Tuple[Int64, Int64, Int64]:
        """The dense `(offset, len, row_count)` for plan row `plan_row`,
        partition `partition` (LIFTED mode). Raises if out of bounds — the
        dense-index invariant means every (row, partition) is enumerable."""
        var r = Int(self.partition_count)
        var base = (plan_row * r + partition) * 3
        if base < 0 or base + 3 > len(self.read_plan_index):
            raise Error(
                "shuffle_seal: dense_slot out of range (row="
                + String(plan_row)
                + ", partition="
                + String(partition)
                + ")"
            )
        return (
            self.read_plan_index[base],
            self.read_plan_index[base + 1],
            self.read_plan_index[base + 2],
        )


def encode_step_complete(seal: StepComplete) -> List[UInt8]:
    """Encode a `StepComplete` to the seal-body wire format (little-endian).

    Round-trips BOTH index modes. In TRAILER_FALLBACK the read-plan lists are
    encoded as empty (their length prefixes are 0) — the decoder reconstructs
    them empty and reads `entries_floor`/`entries_ceiling` instead.
    """
    var out = List[UInt8]()
    put_i64_le(out, _SEAL_MAGIC)
    put_i64_le(out, seal.shuffle_id)
    put_i64_le(out, seal.step_id)
    put_i64_le(out, seal.partition_count)
    put_i64_le(out, Int64(Int(seal.index_mode)))  # mode as i64 for uniform LE
    put_i64_list(out, seal.expected_producers)
    put_i64_list(out, seal.committed_producers)
    put_i64_list(out, seal.read_plan_producer_ids)
    put_str_list(out, seal.read_plan_object_keys)
    put_i64_list(out, seal.read_plan_index)
    put_i64_le(out, seal.entries_floor)
    put_i64_le(out, seal.entries_ceiling)
    return out^


def decode_step_complete(bytes: List[UInt8]) raises -> StepComplete:
    """Decode a `StepComplete` from the seal-body wire format. Raises on a bad
    magic (corrupt/truncated seal) or truncation."""
    var magic = get_i64_le(bytes, 0)
    if magic != _SEAL_MAGIC:
        raise Error("shuffle_seal: bad seal magic (corrupt/truncated body)")
    var shuffle_id = get_i64_le(bytes, 8)
    var step_id = get_i64_le(bytes, 16)
    var partition_count = get_i64_le(bytes, 24)
    var mode_i = get_i64_le(bytes, 32)
    var index_mode = UInt8(Int(mode_i))
    var off = 40

    var exp_pair = get_i64_list(bytes, off)
    var expected = exp_pair[0].copy()
    off = exp_pair[1]

    var com_pair = get_i64_list(bytes, off)
    var committed = com_pair[0].copy()
    off = com_pair[1]

    var rpid_pair = get_i64_list(bytes, off)
    var rp_pids = rpid_pair[0].copy()
    off = rpid_pair[1]

    var rkey_pair = get_str_list(bytes, off)
    var rp_keys = rkey_pair[0].copy()
    off = rkey_pair[1]

    var ridx_pair = get_i64_list(bytes, off)
    var rp_index = ridx_pair[0].copy()
    off = ridx_pair[1]

    var entries_floor = get_i64_le(bytes, off)
    var entries_ceiling = get_i64_le(bytes, off + 8)

    return StepComplete(
        shuffle_id,
        step_id,
        partition_count,
        index_mode,
        expected^,
        committed^,
        rp_pids^,
        rp_keys^,
        rp_index^,
        entries_floor,
        entries_ceiling,
    )


# -----------------------------------------------------------------------------
# Set helpers — sorted-list "sets" of producer ids.
# -----------------------------------------------------------------------------


def sorted_unique_i64(xs: List[Int64]) -> List[Int64]:
    """Return a SORTED, de-duplicated copy of `xs` (the set-normal form). Used
    so `committed`/`expected` compare as SETS:
    a replayed producer that landed a duplicate `_entries` entry collapses to
    ONE member here. Insertion sort — producer counts are small."""
    var out = List[Int64]()
    for i in range(len(xs)):
        var v = xs[i]
        # skip if already present (dedup)
        var present = False
        for j in range(len(out)):
            if out[j] == v:
                present = True
                break
        if present:
            continue
        # insert in sorted position
        var k = len(out)
        out.append(v)
        while k > 0 and out[k - 1] > v:
            out[k] = out[k - 1]
            out[k - 1] = v
            k -= 1
    return out^


def i64_sets_equal(a: List[Int64], b: List[Int64]) -> Bool:
    """Set-equality of two SORTED-UNIQUE lists (`sorted_unique_i64` output).
    Order-stable element-wise compare (`committed == expected` as
    sets, NOT `len(committed) == len(expected)`)."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def i64_set_contains_all(superset: List[Int64], subset: List[Int64]) -> Bool:
    """True iff every element of `subset` is in `superset` (both SORTED-UNIQUE).
    `committed_producers ⊊ expected_producers` (a missing producer) is detected
    as `contains_all(committed, expected) == False`."""
    var i = 0
    var j = 0
    while j < len(subset):
        while i < len(superset) and superset[i] < subset[j]:
            i += 1
        if i >= len(superset) or superset[i] != subset[j]:
            return False
        j += 1
    return True
