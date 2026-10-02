# =============================================================================
# komira_broker/producer_dedupe.mojo
#   The idempotent-producer dedupe decision (exactly-once: idempotence).
# =============================================================================
#
# The PURE sequence-dedupe decision function. Given an incoming
# batch's (producer_epoch, first_seq, last_seq), the producer's registered
# epoch, and the last-committed sequence for this (producer_id, partition),
# decide whether to ACCEPT / treat as DUPLICATE / reject as OUT_OF_ORDER /
# reject as FENCED. This is a side-effect-free POD function so it can be unit
# tested in isolation AND reused verbatim by the data-plane gate (which feeds
# it the registry epoch + the manifest-recovered last-committed seq).
#
# Dedupe rule (per (producer_id, partition), epoch-fenced):
#   * epoch < registered_epoch        → FENCED        (zombie producer)
#   * first_seq <= last_committed_seq  → DUPLICATE     (already committed; ack
#                                                       success, NO re-write)
#   * first_seq == last_committed + 1  → ACCEPT        (the expected next batch)
#   * first_seq >  last_committed + 1  → OUT_OF_ORDER  (a gap; retryable)
#
# First-ever produce: last_committed_seq is -1 (sentinel), so a first_seq of 0
# is `== last + 1` → ACCEPT, and any first_seq > 0 is a gap → OUT_OF_ORDER.
#
# The epoch fence is checked FIRST: a stale-epoch (zombie) producer is rejected
# regardless of its sequence position. A produce whose epoch is >= the
# registered epoch is NOT fenced by this function (the data plane never sees an
# epoch above the registered one for a live producer; a higher epoch only
# arises transiently before the broker observes the bump — and the registry
# read is the authority there).
#
# Encapsulation: a pure value function + a POD result struct. ZERO pointers.
# =============================================================================


# Dedupe outcomes.
comptime DEDUPE_ACCEPT: Int = 0
comptime DEDUPE_DUPLICATE: Int = 1
comptime DEDUPE_OUT_OF_ORDER: Int = 2
# DEDUPE_FENCED = the PRODUCER-ID epoch fence (a zombie producer whose epoch is
# below the registered one). The server maps it to Kafka INVALID_PRODUCER_EPOCH.
comptime DEDUPE_FENCED: Int = 3
# DEDUPE_LEASE_FENCED = the PARTITION-OWNERSHIP writer-lease
# fence (a stale displaced owner whose writer_lease_epoch < the live
# current_lease_epoch). DISTINCT from DEDUPE_FENCED: the server maps it to Kafka
# NOT_LEADER_OR_FOLLOWER (tells the client to refresh metadata — the correct
# signal for an ownership transfer), NOT INVALID_PRODUCER_EPOCH. Conflating the
# two (both mapped to INVALID_PRODUCER_EPOCH) would send the client the wrong signal.
comptime DEDUPE_LEASE_FENCED: Int = 4


@always_inline
def _write_dedupe_outcome_name[W: Writer](mut writer: W, outcome: Int):
    """WRITE what `dedupe_outcome_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY — and a pair bound
    CROSSED reads the wrong string, or out of bounds."""
    if outcome == DEDUPE_ACCEPT:
        writer.write(String("ACCEPT"))
        return
    if outcome == DEDUPE_DUPLICATE:
        writer.write(String("DUPLICATE"))
        return
    if outcome == DEDUPE_OUT_OF_ORDER:
        writer.write(String("OUT_OF_ORDER"))
        return
    if outcome == DEDUPE_FENCED:
        writer.write(String("FENCED"))
        return
    if outcome == DEDUPE_LEASE_FENCED:
        writer.write(String("LEASE_FENCED"))
        return
    writer.write(String("UNKNOWN"))
    return


@always_inline
def dedupe_outcome_name(outcome: Int) -> String:
    var out = String()
    _write_dedupe_outcome_name(out, outcome)
    return out^


@fieldwise_init
struct SequenceDecision(Copyable, Movable, Deinitable):
    """The dedupe decision for one incoming batch.

    Field layout:
      var outcome: Int            — DEDUPE_ACCEPT / DUPLICATE / OUT_OF_ORDER /
                                    FENCED.
      var new_last_committed: Int64 — the last-committed seq AFTER applying this
                                    batch: on ACCEPT it is `last_seq`; on every
                                    other outcome it is the UNCHANGED prior
                                    `last_committed` (no advance).

    POD (two scalar fields). Not a byte-slab element.
    """

    var outcome: Int
    var new_last_committed: Int64


def decide_sequence(
    incoming_epoch: Int64,
    first_seq: Int64,
    last_seq: Int64,
    registered_epoch: Int64,
    last_committed_seq: Int64,
) -> SequenceDecision:
    """Decide the dedupe outcome for an incoming batch (the pure FSM).

    `incoming_epoch` / `first_seq` / `last_seq` come from the RecordBatch-v2
    header. `registered_epoch` is the producer's current registry epoch.
    `last_committed_seq` is the last sequence committed for this
    (producer_id, partition), or -1 if none.

    See the module header for the rule. `new_last_committed` is `last_seq` on
    ACCEPT and the unchanged `last_committed_seq` otherwise."""
    # Zombie fence first.
    if incoming_epoch < registered_epoch:
        return SequenceDecision(DEDUPE_FENCED, last_committed_seq)
    # Already committed (≤ tail) → duplicate (idempotent ack, no re-write).
    if first_seq <= last_committed_seq:
        return SequenceDecision(DEDUPE_DUPLICATE, last_committed_seq)
    # The expected next batch.
    if first_seq == last_committed_seq + Int64(1):
        return SequenceDecision(DEDUPE_ACCEPT, last_seq)
    # A gap above the tail → out-of-order (retryable).
    return SequenceDecision(DEDUPE_OUT_OF_ORDER, last_committed_seq)
