# =============================================================================
# komira_broker/tests/test_precondition_is_anchored.mojo
#   The broker's lost-CAS classifiers may not read a PATH as a 412
#   (komira-ai/komira#1275).
# =============================================================================
#
# Eight broker classifiers matched a bare `412` anywhere in a store error:
# `broker_core._is_precondition_seg`, `partition_map._conflict_is_precondition`,
# `producer_registry._pr_is_precondition`, `retention._is_precondition`,
# `txn_control._tc_is_precondition`, `txn_registry._tr_is_precondition`,
# `ClusterAssignmentStore.is_precondition_failure` and
# `BrokerBatchAppender.classify_append_error`. Store errors name keys, roots
# and random temp suffixes, so an I/O or credential failure whose path spelled
# `412` was read as "another writer won" (a retry, a re-key, or a spurious
# lost slot). The fix matches `status=412`, the HTTP projection the cloud
# conformers append, instead of the bare digits.
#
# What each case catches:
#   * test_an_io_error_whose_path_spells_412_is_not_a_lost_cas: FAILS BEFORE
#     THE FIX on its first `assert_false` (`_is_precondition_seg`).
#   * test_a_cloud_412_is_still_a_lost_cas: a GCS/Azure 412 carries no
#     `precondition` / `Precondition` word; deleting the `status=412` needle
#     from any one classifier turns this red.
#
# HERMETIC: pure classification; the appender wraps an in-memory store.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_broker.broker_coalescing_produce import (
    BROKER_APPEND_MODE_ESCALATING,
    BrokerBatchAppender,
    _EosResultCell,
)
from komira_broker.broker_core import _is_precondition_seg
from komira_broker.cluster_assignment_store import ClusterAssignmentStore
from komira_broker.partition_map import _conflict_is_precondition
from komira_broker.producer_registry import _pr_is_precondition
from komira_broker.retention import _is_precondition
from komira_broker.txn_control import _tc_is_precondition
from komira_broker.txn_registry import _tr_is_precondition

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.coalescing_window import APPEND_ERR, APPEND_LOST_SLOT
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)


comptime _Slow = SharedInMemorySlowCasStore
comptime _Cas = ClusterAssignmentStore[SharedInMemoryConditionalStore]


def _io_errors() -> List[String]:
    """I/O failures whose only `412` is inside a path."""
    var out = List[String]()
    # LocalFsConditionalStore._write_atomic's message, a root holding 412.
    out.append(
        String(
            "LocalFsConditionalStore: atomic rename failed"
            " ('/srv/412/c/_meta/assignment.tmp.9f3a0c7d1e2b5a68' ->"
            " '/srv/412/c/_meta/assignment', rc=-1)"
        )
    )
    # The same, with the random temp suffix spelling 412.
    out.append(
        String(
            "LocalFsConditionalStore: atomic rename failed"
            " ('/srv/c/topics/t/0/_HEAD.tmp.00c4120e9a7b3d5f' ->"
            " '/srv/c/topics/t/0/_HEAD', rc=-1)"
        )
    )
    # A 403 about manifest chunk 412, in the cloud conformers' shape.
    out.append(
        String(
            "StoreError[PERMISSION_DENIED] PutObject s3://b/c/topics/t/0/manifest/"
            "00000000000000000412.chunk status=403"
        )
    )
    return out^


def _cloud_412s() -> List[String]:
    var out = List[String]()
    out.append(
        String(
            "StoreError[PRECONDITION] WriteObject gs://b/c/topics/t/0/_HEAD"
            " status=412 grpc_code=9"
        )
    )
    out.append(String("StoreError[PRECONDITION] PUT az://c/c/_meta/x status=412"))
    return out^


def _escalating_appender() raises -> BrokerBatchAppender[_Slow]:
    var cell = ArcPointer[_EosResultCell](_EosResultCell())
    return BrokerBatchAppender[_Slow](
        CasManifestStore[_Slow](_Slow(slow_ticks=0), String("c/p")),
        BROKER_APPEND_MODE_ESCALATING,
        cell,
    )


def test_an_io_error_whose_path_spells_412_is_not_a_lost_cas() raises:
    print("[broker-412] an I/O error whose path spells 412 is not a lost CAS")
    var appender = _escalating_appender()
    var errs = _io_errors()
    for i in range(len(errs)):
        var m = errs[i]
        assert_true(m.find("412") >= 0, msg="premise: carries 412: " + m)
        assert_false(_is_precondition_seg(m), msg="broker_core: " + m)
        assert_false(_conflict_is_precondition(m), msg="partition_map: " + m)
        assert_false(_pr_is_precondition(m), msg="producer_registry: " + m)
        assert_false(_is_precondition(m), msg="retention: " + m)
        assert_false(_tc_is_precondition(m), msg="txn_control: " + m)
        assert_false(_tr_is_precondition(m), msg="txn_registry: " + m)
        assert_false(
            _Cas.is_precondition_failure(m), msg="cluster_assignment_store: " + m
        )
        assert_equal(
            appender.classify_append_error(m),
            APPEND_ERR,
            "coalescing produce (escalating): " + m,
        )
    print("  PASS")


def test_a_cloud_412_is_still_a_lost_cas() raises:
    print("[broker-412] a cloud 412 is still a lost CAS")
    var appender = _escalating_appender()
    var errs = _cloud_412s()
    for i in range(len(errs)):
        var m = errs[i]
        assert_true(_is_precondition_seg(m), msg="broker_core: " + m)
        assert_true(_conflict_is_precondition(m), msg="partition_map: " + m)
        assert_true(_pr_is_precondition(m), msg="producer_registry: " + m)
        assert_true(_is_precondition(m), msg="retention: " + m)
        assert_true(_tc_is_precondition(m), msg="txn_control: " + m)
        assert_true(_tr_is_precondition(m), msg="txn_registry: " + m)
        assert_true(
            _Cas.is_precondition_failure(m), msg="cluster_assignment_store: " + m
        )
        assert_equal(
            appender.classify_append_error(m),
            APPEND_LOST_SLOT,
            "coalescing produce (escalating): " + m,
        )
    print("  PASS")


def main() raises:
    test_an_io_error_whose_path_spells_412_is_not_a_lost_cas()
    test_a_cloud_412_is_still_a_lost_cas()
    print("ALL broker precondition anchoring tests PASSED")
