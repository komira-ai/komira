# =============================================================================
# kci_cloud_gcp/tests/test_gcp_names_and_roles.mojo
# =============================================================================
#
# THE ROLE TABLE IS INJECTIVE: attribution reads a binding's IAM role back to
# exactly one (target, access) row (kci_cloud/derived.mojo), so two rows
# sharing a role, or one (target, access) with two roles, would let a
# binding be read as another edge's. This test holds G4's two rows to
# `role_table_problems` (empty), to one row per role and per (target,
# access), and to their exact values; G5's rows join the same table and the
# same test. It goes red if the two rows are mapped to one role.
#
# THE DERIVED NAMES: a pure function of machine, cell and node id, inside
# IAM's account-id rule and Run's job-id rule, different for another cell,
# machine or node, and replaced by the author's physical name when there is
# one.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_cloud import ACCESS_DESCRIBE, ACCESS_WRITE, role_table_problems
from kci_cloud_gcp import (
    KIND_ACCOUNT,
    ROLE_ACCOUNT_VIEWER,
    ROLE_LOG_WRITER,
    account_email,
    account_member,
    account_resource,
    derived_name,
    display_name_of,
    gcp_role_table,
    job_resource,
    object_name,
    project_resource,
)


def test_the_role_table_is_injective() raises:
    var rows = gcp_role_table()
    var problems = role_table_problems(rows)
    assert_equal(len(problems), 0, problems[0] if len(problems) > 0 else String(""))
    for i in range(len(rows)):
        var same_role = 0
        var same_edge = 0
        for k in range(len(rows)):
            if rows[k].role == rows[i].role:
                same_role += 1
            if rows[k].target == rows[i].target and rows[k].access == rows[i].access:
                same_edge += 1
        assert_equal(same_role, 1, rows[i].role + " is on one row")
        assert_equal(same_edge, 1, rows[i].target + " " + rows[i].access + " has one role")


def test_g4_rows() raises:
    var rows = gcp_role_table()
    assert_equal(len(rows), 2)
    assert_equal(rows[0].target, String(KIND_ACCOUNT))
    assert_equal(rows[0].access, String(ACCESS_DESCRIBE))
    assert_equal(rows[0].role, "roles/iam.serviceAccountViewer")
    assert_equal(rows[1].target, "cell/LOGS")
    assert_equal(rows[1].access, String(ACCESS_WRITE))
    assert_equal(rows[1].role, "roles/logging.logWriter")
    assert_equal(String(ROLE_ACCOUNT_VIEWER), rows[0].role)
    assert_equal(String(ROLE_LOG_WRITER), rows[1].role)


def _legal_id(id: String) -> Bool:
    var b = id.as_bytes()
    if len(b) < 6 or len(b) > 30:
        return False
    if not (b[0] >= UInt8(ord("a")) and b[0] <= UInt8(ord("z"))):
        return False
    if b[len(b) - 1] == UInt8(ord("-")):
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("a") and c <= ord("z")) or (c >= ord("0") and c <= ord("9")) or c == ord("-")):
            return False
    return True


def test_derived_names() raises:
    var n = derived_name(String("shop"), String("staging"), String("peer/identity"))
    assert_true(n.startswith("kci-"), n)
    assert_equal(n.byte_length(), 14)
    assert_true(_legal_id(n), n + " is inside IAM's account-id rule")
    assert_equal(n, derived_name(String("shop"), String("staging"), String("peer/identity")), "a pure function")
    assert_true(n != derived_name(String("shop"), String("prod"), String("peer/identity")), "another cell")
    assert_true(n != derived_name(String("cafe"), String("staging"), String("peer/identity")), "another machine")
    assert_true(n != derived_name(String("shop"), String("staging"), String("runner/identity")), "another node")
    var long_path = String("web/api/workers/batch/nightly/identity")
    assert_true(_legal_id(derived_name(String("a-very-long-machine-name"), String("a-very-long-cell-name"), long_path)))


def test_names_of_objects() raises:
    assert_equal(object_name(String("shop"), String("staging"), String("peer/identity"), String("kitadopt")), "kitadopt")
    assert_equal(
        object_name(String("shop"), String("staging"), String("peer/identity"), String("")),
        derived_name(String("shop"), String("staging"), String("peer/identity")),
    )
    var email = account_email(String("runner-01"), String("demo-project"))
    assert_equal(email, String("runner-01") + "@" + "demo-project.iam.gserviceaccount.com")
    assert_equal(account_member(email), String("serviceAccount:") + email)
    assert_equal(account_resource(String("demo-project"), email), String("projects/demo-project/serviceAccounts/") + email)
    assert_equal(project_resource(String("demo-project")), "projects/demo-project")
    assert_equal(
        job_resource(String("demo-project"), String("europe-west1"), String("nightly-1")),
        "projects/demo-project/locations/europe-west1/jobs/nightly-1",
    )
    assert_equal(display_name_of(String("peer/identity")), "peer/identity")


def main() raises:
    print("test_the_role_table_is_injective")
    test_the_role_table_is_injective()
    print("test_g4_rows")
    test_g4_rows()
    print("test_derived_names")
    test_derived_names()
    print("test_names_of_objects")
    test_names_of_objects()
    print("OK")
