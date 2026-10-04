# =============================================================================
# komira_objectstore/tests/test_cas_manifest_absence_is_anchored.mojo —
#   `cas_manifest._is_not_found` may not read an OBJECT KEY.
# =============================================================================
#
# ⛔ THE DEFECT. `cas_manifest._is_not_found` was an unanchored substring scan:
#
#     msg.find("not_found") | msg.find("NotFound") | msg.find("404")
#                           | msg.find("NoSuchKey")
#
# and EVERY production store conformer builds its error message around the OBJECT
# KEY. `komira_aws_s3.s3._mk_error` emits
#
#     StoreError[<KIND>] <method> s3://<bucket>/<key> status=<http> s3_code=...
#
# and `gcs_grpc_errors.map_grpc_error_to_store_error` the same shape with `gs://`.
# So a `PERMISSION_DENIED` or a `5xx` about a key containing the three characters
# `404` answered TRUE: **the credential failure became "the object is absent"**.
#
# ★ AND HERE THE COLLIDING KEY IS NOT A LOTTERY — IT IS ARITHMETIC. A manifest
# chunk key is `<prefix>/manifest/<chunk_seq:020d>.chunk`
# (`cas_manifest.chunk_key` / `_seq_from_key`), so the key for chunk sequence 404
# is literally
#
#     <prefix>/manifest/00000000000000000404.chunk
#
# and so is 1404, 4040, 40400, 14040, … . `komira_telemetry_read.scan_plan`
# narrowed the identical predicate because its 16 random hex characters contain
# `404` "one in a few dozen runs"; here the partition simply REACHES sequence 404
# and stays colliding for a fixed, dense, entirely predictable set of sequences
# for the rest of its life. The prefix is caller-supplied on top of that.
#
# === WHY IT IS A WRONG ANSWER AND NOT A MISSING ONE ===
# `_is_not_found` is the swallow at thirteen call sites in `cas_manifest`, and the
# ones this file is named for are the two single-object sidecars:
#
#   * `read_log_start`   — a 403 on `<prefix>/_LOG_START` returns `LogStart.zero()`
#                          = "this partition has never been truncated", so the
#                          next advance CREATEs with `If-None-Match` instead of
#                          CAS-ing the real pointer.
#   * `read_catalog_sidecar` (`_CATALOG`) — a 403 returns `CatalogSidecar.absent()`
#                          = "this prefix has no catalog", and the next write
#                          CREATEs over the top of a catalog that exists.
#   * `_is_marked` (`tombstones/`), and the chunk reads around `log_start_seq`.
#
# Every one of those turns "I could not read it" into "there is nothing there",
# with no log line, because as far as the code is concerned nothing went wrong.
#
# === THE NARROWING, AND IT IS NOT NEW POLICY ===
# ⛔ `status=404`, NOT a bare `404` — **the `=` is the load-bearing character, not
# the digits**. Two in-tree siblings already state exactly this and were narrowed
# for exactly this reason:
#
#   * `komira_telemetry_read.scan_plan._is_not_found`
#   * `src/cmd/cp_telemetry_validator/cp_telem_lib._store_error_says_not_found`
#     (whose docstring names `cas_manifest._is_not_found` BY NAME as one of the
#      two copies that still matched a bare `404`)
#
# and `komira_gcp_storage.gcs_grpc_conditional_store._is_not_found` is narrower
# still. The needle set below is `cp_telem_lib`'s, verbatim: every needle is one
# a key cannot contain, because the key alphabet admits no `[`, `]`, `=` or `_`
# and the canonical token is uppercase.
#
# === WHAT IS FALSIFIED HERE ===
#   test_a_403_about_chunk_404_is_NOT_absence          ★ the headline
#   test_every_non_404_status_about_chunk_404_is_NOT_absence
#   test_the_log_start_and_catalog_sidecar_keys_collide_too
#   test_a_real_s3_and_gcs_404_are_STILL_absence       ⛔ the non-regression half
#   test_the_in_tree_conformer_message_is_STILL_absence — driven through a REAL
#       `InMemoryConditionalStore.get` on a missing key, so the offline path is
#       pinned against the producer rather than against a transcription.
#   test_the_key_alphabet_claim_holds                   the premise, asserted
#
# HERMETIC. Pure value logic + one in-memory store. No cloud, no sockets, no fs.
# =============================================================================

from std.testing import assert_true, assert_false

from komira_objectstore.cas_manifest import (
    _is_not_found,
    catalog_key,
    chunk_key,
    log_start_key,
)
from komira_objectstore import InMemoryConditionalStore


comptime _PREFIX: String = "topic-orders/p7"


def _s3_error(kind: String, status: Int, key: String) -> String:
    """The message `komira_aws_s3.s3._mk_error` builds, transcribed from its
    body (`StoreError[<KIND>] <method> s3://<bucket>/<key> status=<http> ...`).
    It is transcribed rather than called because `komira_objectstore` is BELOW
    every cloud conformer in the dep graph — importing one here would invert the
    layering this package exists to keep clean."""
    var m = String("StoreError[")
    m += kind
    m += String("] GetObject s3://example-broker/")
    m += key
    m += String(" status=")
    m += String(status)
    return m^


def test_the_key_alphabet_claim_holds() raises:
    """THE PREMISE, ASSERTED RATHER THAN ASSUMED. The narrowing is only sound if
    a manifest key really can contain `404` and really cannot contain `=` or a
    bracket. Both halves are checked against the REAL key builders."""
    var k = chunk_key(String(_PREFIX), Int64(404)).raw()
    assert_true(
        k.find(String("404")) >= 0,
        msg=(
            "the chunk-404 key must literally contain `404` — that is the whole"
            " hazard: "
            + k
        ),
    )
    assert_true(
        k.find(String("=")) < 0 and k.find(String("[")) < 0,
        msg="a manifest key admits no `=` and no bracket: " + k,
    )


def test_a_403_about_chunk_404_is_NOT_absence() raises:
    """★ THE HEADLINE. A PERMISSION_DENIED reading manifest chunk 404 is a
    credential failure, not an empty manifest.

    FAILS BEFORE THE FIX: the predicate scans the whole message for `404`, finds
    it in `00000000000000000404.chunk`, and answers True — so the replay treats a
    live chunk as missing and stops, reporting FEWER entries with no error at
    all."""
    var msg = _s3_error(
        String("PERMISSION_DENIED"),
        403,
        chunk_key(String(_PREFIX), Int64(404)).raw(),
    )
    assert_true(
        msg.find(String("404")) >= 0,
        msg="precondition: the message DOES carry `404`, inside the key",
    )
    assert_false(
        _is_not_found(msg),
        msg=(
            "a PERMISSION_DENIED about chunk 404 is NOT an absent object — a"
            " broken credential and an empty manifest must not be the same"
            " observation: "
            + msg
        ),
    )


def test_every_non_404_status_about_chunk_404_is_NOT_absence() raises:
    """The CLASS, not the one status, and over the DENSE colliding set — 404,
    1404, 4040, 40400 are all keys carrying `404`, and there are infinitely many
    more. Nothing here proves absence."""
    var kinds = List[String]()
    var statuses = List[Int]()
    kinds.append(String("PERMISSION_DENIED"))
    statuses.append(403)
    kinds.append(String("THROTTLED"))
    statuses.append(429)
    kinds.append(String("TRANSPORT"))
    statuses.append(500)
    kinds.append(String("TRANSPORT"))
    statuses.append(503)
    kinds.append(String("MALFORMED"))
    statuses.append(400)

    var seqs = List[Int64]()
    seqs.append(Int64(404))
    seqs.append(Int64(1404))
    seqs.append(Int64(4040))
    seqs.append(Int64(40400))

    for s in range(len(seqs)):
        for i in range(len(kinds)):
            var msg = _s3_error(
                kinds[i], statuses[i], chunk_key(String(_PREFIX), seqs[s]).raw()
            )
            assert_false(
                _is_not_found(msg),
                msg=(
                    "not an absence — a chunk sequence that merely SPELLS 404"
                    " cannot change an error's class: "
                    + msg
                ),
            )


def test_the_log_start_and_catalog_sidecar_keys_collide_too() raises:
    """The two single-object sidecars this file is named for. Their keys are
    fixed, but the PREFIX is caller-supplied — a topic or partition prefix
    carrying `404` makes every `_LOG_START` / `_CATALOG` read on that partition
    collide, permanently, for every request it will ever make.

    The consequence is not a slow read: `read_log_start` answers
    `LogStart.zero()` (never truncated) and `read_catalog_sidecar` answers
    `CatalogSidecar.absent()` (no catalog), and the next writer then CREATEs with
    `If-None-Match` over state that exists."""
    var prefix = String("topic-orders-404/p0")
    var keys = List[String]()
    keys.append(log_start_key(prefix).raw())
    keys.append(catalog_key(prefix).raw())
    for i in range(len(keys)):
        assert_true(
            keys[i].find(String("404")) >= 0,
            msg="precondition: this sidecar key carries `404`: " + keys[i],
        )
        var msg = _s3_error(String("PERMISSION_DENIED"), 403, keys[i])
        assert_false(
            _is_not_found(msg),
            msg=(
                "a 403 on a sidecar is NOT `never written` — answering absent"
                " here makes the next write CREATE over live state: "
                + msg
            ),
        )


def test_a_real_s3_and_gcs_404_are_STILL_absence() raises:
    """⛔ THE NON-REGRESSION HALF, and the one that matters. `read_log_start`,
    `read_catalog_sidecar`, `_is_marked` and the recovery scan ALL depend on a
    genuine absence being swallowed. If this narrowing broke that, a never-written
    sidecar would start raising and every fresh partition would fail to open —
    strictly worse than the defect. Both cloud conformers stamp the canonical
    uppercase token AND `status=404`, neither of which a key can spell."""
    var s3 = _s3_error(
        String("NOT_FOUND"), 404, chunk_key(String(_PREFIX), Int64(7)).raw()
    )
    assert_true(_is_not_found(s3), msg="a genuine S3 404 is an absence: " + s3)

    var gcs = String(
        "StoreError[NOT_FOUND] ReadObject gs://example-broker/"
    )
    gcs += log_start_key(String(_PREFIX)).raw()
    gcs += String(" status=404 grpc_code=5 grpc_detail=object not found")
    assert_true(_is_not_found(gcs), msg="a genuine GCS 404 is an absence: " + gcs)

    # The XML/S3-family code token, which carries neither the bracket nor `=`.
    assert_true(
        _is_not_found(
            String("S3 GetObject failed: NoSuchKey for ")
            + chunk_key(String(_PREFIX), Int64(7)).raw()
        ),
        msg="the XML conformer's NoSuchKey code is still an absence",
    )


def test_the_in_tree_conformer_message_is_STILL_absence() raises:
    """Driven through a REAL conformer rather than a transcription: ask
    `InMemoryConditionalStore` for a key it does not hold and classify the
    message it ACTUALLY raises. Every offline broker/pgstore test in the tree
    reaches `_is_not_found` through this exact string, so if the narrowing missed
    its spelling the whole offline suite would start failing on absence."""
    var store = InMemoryConditionalStore()
    var missing = chunk_key(String(_PREFIX), Int64(404))
    var raised = String("")
    try:
        var _b = store.get(missing)
        _ = _b
    except e:
        raised = String(e)
    assert_true(
        raised.byte_length() > 0,
        msg="precondition: reading a missing key must raise",
    )
    assert_true(
        _is_not_found(raised),
        msg=(
            "the in-memory conformer's own not-found message must still classify"
            " absent: "
            + raised
        ),
    )


def main() raises:
    test_the_key_alphabet_claim_holds()
    test_a_403_about_chunk_404_is_NOT_absence()
    test_every_non_404_status_about_chunk_404_is_NOT_absence()
    test_the_log_start_and_catalog_sidecar_keys_collide_too()
    test_a_real_s3_and_gcs_404_are_STILL_absence()
    test_the_in_tree_conformer_message_is_STILL_absence()
    print("test_cas_manifest_absence_is_anchored: ALL PASS")
