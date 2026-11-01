# =============================================================================
# komira_broker_coordinator/tests/test_reassign_precondition_is_anchored.mojo
#   The parkable reassign op's lost-CAS classifier may not read a PATH as a
#   412 (komira-ai/komira#1275).
# =============================================================================
#
# `AsyncReassignOp._is_precondition_failure` decides between "lost the CAS,
# re-read and retry" and "terminal error". It matched a bare `412` anywhere in
# the store error, so an I/O failure whose root, key or temp suffix spelled
# `412` looped back to READ instead of failing. The fix matches `status=412`,
# the HTTP projection the cloud conformers append, instead of the bare digits.
#
# What each case catches:
#   * test_an_io_error_whose_path_spells_412_is_not_a_lost_cas: FAILS BEFORE
#     THE FIX on its `assert_false`.
#   * test_a_cloud_412_is_still_a_lost_cas: a GCS/Azure 412 carries none of
#     `precondition`, `If-Match`, `If-None-Match`; deleting the `status=412`
#     needle turns it red.
#
# HERMETIC: pure classification, no store is driven.
# =============================================================================

from std.testing import assert_false, assert_true

from komira_broker_coordinator.broker_heartbeat_suspendable import (
    AsyncReassignOp,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)


comptime _Op = AsyncReassignOp[SharedInMemorySlowCasStore]


def test_an_io_error_whose_path_spells_412_is_not_a_lost_cas() raises:
    print("[reassign-412] an I/O error whose path spells 412 is not a lost CAS")
    var errs = List[String]()
    errs.append(
        String(
            "LocalFsConditionalStore: atomic rename failed"
            " ('/srv/412/c/_meta/assignment.tmp.9f3a0c7d1e2b5a68' ->"
            " '/srv/412/c/_meta/assignment', rc=-1)"
        )
    )
    errs.append(
        String(
            "StoreError[PERMISSION_DENIED] PutObject s3://b/c-412/_meta/"
            "assignment status=403"
        )
    )
    for i in range(len(errs)):
        var m = errs[i]
        assert_true(m.find("412") >= 0, msg="premise: carries 412: " + m)
        assert_false(_Op._is_precondition_failure(m), msg=m)
    print("  PASS")


def test_a_cloud_412_is_still_a_lost_cas() raises:
    print("[reassign-412] a cloud 412 is still a lost CAS")
    var errs = List[String]()
    errs.append(
        String(
            "StoreError[PRECONDITION] WriteObject gs://b/c/_meta/assignment"
            " status=412 grpc_code=9"
        )
    )
    errs.append(String("StoreError[PRECONDITION] PUT az://c/c/_meta/x status=412"))
    for i in range(len(errs)):
        assert_true(_Op._is_precondition_failure(errs[i]), msg=errs[i])
    print("  PASS")


def main() raises:
    test_an_io_error_whose_path_spells_412_is_not_a_lost_cas()
    test_a_cloud_412_is_still_a_lost_cas()
    print("ALL reassign precondition anchoring tests PASSED")
