# =============================================================================
# komira_objectstore/tests/test_precondition_is_anchored.mojo
#   `cas_manifest._is_precondition` (and its public spelling `is_precondition`)
#   may not read a PATH as a lost compare-and-swap (komira-ai/komira#1275).
# =============================================================================
#
# The defect: the predicate matched a bare `412` anywhere in the message. Store
# errors carry paths, keys and random temp suffixes, and any of them can spell
# `412`. A LocalFs rename failure under a root holding `412`, or a 403 about
# manifest chunk 412 (`.../manifest/00000000000000000412.chunk`), then read as
# "another writer won the slot" instead of as an I/O or credential failure.
#
# The fix keeps the word needles and replaces the bare `412` with `status=412`,
# the HTTP projection every cloud conformer appends (`StoreError[<KIND>] ...
# status=<http>`). A path cannot spell it by accident the way it spells three
# digits; the in-tree conformers say `precondition (412)`.
#
# What each case catches:
#   * test_a_real_rename_failure_under_a_412_root_is_not_a_lost_cas: the
#     headline, driven through a REAL LocalFsConditionalStore rename failure.
#     FAILS BEFORE THE FIX on the `assert_false(_is_precondition(msg))` line:
#     the root holds `412`, and the old predicate matched it.
#   * test_a_403_about_chunk_412_is_not_a_lost_cas: the arithmetic collision
#     (chunk sequence 412 spells it in the key), on every non-412 status.
#   * test_cloud_412s_are_still_a_lost_cas: the non-regression half. A GCS or
#     Azure 412 carries no lowercase `precondition`; before the fix only the
#     bare `412` caught it. Deleting the `status=412` needle turns this red.
#   * test_the_in_tree_conformer_412_is_still_a_lost_cas: a REAL
#     InMemoryConditionalStore create conflict, classified as raised.
#
# HERMETIC: one in-memory store and one LocalFs root under the test tmpdir.
# =============================================================================

from std.testing import assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.cas_manifest import (
    _is_precondition,
    chunk_key,
    is_precondition,
)
from komira_objectstore import InMemoryConditionalStore
from komira_objectstore.local_fs_conditional_store import LocalFsConditionalStore
from komira_objectstore.path import Path
from komira_objectstore.types import WritePrecondition
from komira_runtime_paths import test_tmpdir


comptime _PREFIX: String = "topic-orders/p7"


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _cloud_error(scheme: String, kind: String, status: Int, key: String) -> String:
    """The shape every cloud conformer raises:
    `StoreError[<KIND>] <method> <scheme>://<bucket>/<key> status=<http>`
    (`komira_objectstore_s3.errors.s3_store_error`, the GCS gRPC mapper, the
    Azure blob store). Transcribed: those packages sit above this one."""
    var m = String("StoreError[") + kind + "] PutObject " + scheme
    m += "://example-broker/" + key + " status=" + String(status)
    return m^


def test_a_real_rename_failure_under_a_412_root_is_not_a_lost_cas() raises:
    """The message is produced by the store, not transcribed. `<root>/d` is a
    directory, so an unconditional put of key `d` cannot rename its temp over
    it, and the store raises `atomic rename failed ('<root>/d.tmp.<hex>' ->
    '<root>/d', rc=N)`. The root holds `412` on every run."""
    var root = (
        test_tmpdir() + String("/komira_precond_412_")
        + String(UInt64(perf_counter_ns()))
    )
    var s = LocalFsConditionalStore(root.copy())
    var inner = LocalFsConditionalStore(root + "/d")
    _ = inner.put(Path.parse(String("x")), _b("1"))
    var msg = String("")
    try:
        _ = s.put(Path.parse(String("d")), _b("payload"))
    except e:
        msg = String(e)
    assert_true(msg.find("atomic rename failed") >= 0, msg=msg)
    assert_true(
        msg.find("412") >= 0,
        msg="premise: the rename error carries `412`, in the root: " + msg,
    )
    assert_false(
        _is_precondition(msg),
        msg="an I/O failure whose path spells 412 is not a lost CAS: " + msg,
    )
    assert_false(
        is_precondition(msg),
        msg="the public spelling agrees: " + msg,
    )


def test_a_403_about_chunk_412_is_not_a_lost_cas() raises:
    var key = chunk_key(String(_PREFIX), Int64(412)).raw()
    assert_true(
        key.find("412") >= 0,
        msg="premise: the chunk-412 key spells `412`: " + key,
    )
    var kinds = List[String]()
    var statuses = List[Int]()
    kinds.append(String("PERMISSION_DENIED"))
    statuses.append(403)
    kinds.append(String("THROTTLED"))
    statuses.append(503)
    kinds.append(String("TRANSPORT"))
    statuses.append(500)
    kinds.append(String("NOT_FOUND"))
    statuses.append(404)
    for i in range(len(kinds)):
        var msg = _cloud_error(String("s3"), kinds[i], statuses[i], key)
        assert_false(
            _is_precondition(msg),
            msg="a non-412 status about chunk 412 is not a lost CAS: " + msg,
        )


def test_cloud_412s_are_still_a_lost_cas() raises:
    var key = chunk_key(String(_PREFIX), Int64(7)).raw()
    var gcs = _cloud_error(String("gs"), String("PRECONDITION"), 412, key)
    gcs += String(" grpc_code=9 grpc_detail=precondition failed")
    assert_true(_is_precondition(gcs), msg="a GCS 412 is a lost CAS: " + gcs)
    # Neither of these spells a lowercase or capitalised `precondition`: the
    # only needle that can catch them is `status=412`.
    var azure = _cloud_error(String("az"), String("PRECONDITION"), 412, key)
    assert_true(_is_precondition(azure), msg="an Azure 412 is a lost CAS: " + azure)
    var s3 = _cloud_error(String("s3"), String("PRECONDITION"), 412, key)
    assert_true(is_precondition(s3), msg="an S3 412 is a lost CAS: " + s3)


def test_the_in_tree_conformer_412_is_still_a_lost_cas() raises:
    var store = InMemoryConditionalStore()
    var key = chunk_key(String(_PREFIX), Int64(412))
    _ = store.conditional_put(key, _b("a"), WritePrecondition.if_none_match_star())
    var raised = String("")
    try:
        _ = store.conditional_put(
            key, _b("b"), WritePrecondition.if_none_match_star()
        )
    except e:
        raised = String(e)
    assert_true(raised.byte_length() > 0, msg="the second create must raise")
    assert_true(
        _is_precondition(raised),
        msg="the in-memory conformer's create conflict is a lost CAS: " + raised,
    )


def main() raises:
    test_a_real_rename_failure_under_a_412_root_is_not_a_lost_cas()
    test_a_403_about_chunk_412_is_not_a_lost_cas()
    test_cloud_412s_are_still_a_lost_cas()
    test_the_in_tree_conformer_412_is_still_a_lost_cas()
    print("test_precondition_is_anchored: ALL PASS")
