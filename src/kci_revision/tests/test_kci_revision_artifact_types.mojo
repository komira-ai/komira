# =============================================================================
# kci_revision/tests/test_kci_revision_artifact_types.mojo
#   — THE ARTIFACT-TYPE TABLE'S OWN GATE, welded to the library that owns it.
# =============================================================================
#
# `artifact_types.mojo` is layer 1 of kci's artifact types: the ONLY list of
# artifact types, one row per revision role. It lives in `kci_revision`, so its
# invariants are this library's welded tests, and the library cannot build while
# any of them fails. Every consumer of the table (the stage decision today, the
# package classifier and stager later) inherits the weld.
#
# What is NOT here, on purpose: the ROUTING. `WIRED_STAGE_LEGS` and `drive_stage`
# live in kci's revision CLI, a source of the kci binary rather than of this
# library, so the routing rows (the package+probe refusal, the returned-bits
# check, the per-row totality over the table and the wired-legs pin) are tested
# with that binary, which co-compiles that file.
#
# Rule applied throughout (this package's convention): A TEST I CANNOT SEE FAIL IS
# WORTHLESS. Each test names the mutant it goes RED against.
#
#   (1) test_every_row_is_keyed_and_carries_one_declared_leg
#       MUTANT: a row whose leg is not a declared bit (a leg nothing can route),
#       a row carrying two legs, or a duplicated role (the second row would be
#       unreachable through `row_for_role`). Also pins SERVICE and PROBE as ONE
#       type on TWO legs — merging them erases the binding's probe-without-env
#       refusal.
#   (2) test_the_transports_partition_the_declared_legs
#       MUTANT: a declared leg with no transport, or one leg on two transports.
#   (3) test_row_for_role_refuses_a_role_with_no_row
#       MUTANT: answer an unknown role with a default row (leg NONE) — exactly how
#       an unknown artifact used to vanish from `stage`.
#   (4) test_the_stageable_roles_are_derived_from_the_table
#       MUTANT: a hand-typed role list in the "nothing to stage" message, which is
#       how the old one came to omit `probe`.
#   (5) test_stage_leg_names_names_every_bit_and_an_undeclared_one
#       MUTANT: drop a bit it does not recognise — an unknown leg would then be
#       invisible in the very refusal that exists to name it.
#   (6) test_package_version_puts_the_ordinal_in_the_patch_position
#       MUTANT: accept ordinal 0 (the unstamped SENTINEL every producer builds).
#   (7) test_a_two_subdir_conda_pair_keys_to_two_rows
#       MUTANT: key a package file on its file name alone. A conda file name does
#       not carry the platform, so the linux-64 and osx-arm64 files of one
#       revision would share a key.
#
# Pure values: no store, no network, no runtime data. Mojo 1.0 (def-only).
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_revision import (
    REVISION_ROLE_PROBE,
    REVISION_ROLE_SERVICE,
    REVISION_ROLE_WEB_CONTENT,
)
from kci_revision.artifact_types import (
    artifact_type_rows,
    row_for_role,
    known_roles_text,
    stageable_roles_text,
    stage_leg_names,
    package_version,
    package_file_key,
    package_subdirs,
    ARTIFACT_TYPE_OCI_IMAGE,
    ARTIFACT_TYPE_CONTENT_BLOB,
    ARTIFACT_TYPE_PYTHON_WHEEL,
    ARTIFACT_TYPE_CONDA_PACKAGE,
    ARTIFACT_TYPE_NPM_PACKAGE,
    ARTIFACT_TYPE_BUILD_TOOL,
    REVISION_ROLE_PYTHON_WHEEL,
    REVISION_ROLE_CONDA_PACKAGE,
    REVISION_ROLE_NPM_PACKAGE,
    REVISION_ROLE_PACKAGE_STAMP_TOOL,
    PACKAGE_SUBDIR_LINUX_64,
    PACKAGE_SUBDIR_OSX_ARM64,
    PACKAGE_SUBDIR_NOARCH,
    STAGE_LEG_NONE,
    STAGE_LEG_WEB,
    STAGE_LEG_SERVICE,
    STAGE_LEG_PROBE,
    STAGE_LEG_PACKAGE,
    DECLARED_STAGE_LEGS,
    STAGE_TRANSPORT_CONTENT_LEGS,
    STAGE_TRANSPORT_OCI_LEGS,
    STAGE_TRANSPORT_PACKAGE_LEGS,
)


def _assert_row(
    role: String, type_name: String, leg: Int, suffix: String
) raises:
    var row = row_for_role(role)
    assert_equal(row.role, role, role + " looks up to itself")
    assert_equal(row.type_name, type_name, role + "'s type")
    assert_equal(row.stage_leg, leg, role + "'s stage leg")
    assert_equal(row.file_suffix, suffix, role + "'s file suffix")


def test_every_row_is_keyed_and_carries_one_declared_leg() raises:
    var rows = artifact_type_rows()
    for i in range(len(rows)):
        ref row = rows[i]
        assert_true(row.role.byte_length() > 0, "every row has a role")
        assert_true(row.type_name.byte_length() > 0, row.role + " has a type")
        assert_true(
            row.filename_grammar.byte_length() > 0
            and row.version_grammar.byte_length() > 0,
            row.role + " states its file and version grammar",
        )
        var leg = row.stage_leg
        assert_true(
            (leg & ~DECLARED_STAGE_LEGS) == 0,
            row.role + "'s leg " + String(leg) + " is a DECLARED bit (or NONE)",
        )
        assert_true(
            (leg & (leg - 1)) == 0,
            row.role + "'s leg is ONE bit — a row has one leg",
        )
        for j in range(i + 1, len(rows)):
            assert_true(rows[j].role != row.role, "roles are unique: " + row.role)
    # Checked AFTER the per-row invariants, so a row added on a bad leg is
    # reported as that, not as a count change.
    assert_equal(len(rows), 7, "the seven rows of the table")

    # The rows, each pinned. SERVICE and PROBE: ONE type, TWO legs (merging them
    # into one OCI value would erase what the stage binding needs to tell
    # apart).
    _assert_row(
        String(REVISION_ROLE_SERVICE),
        String(ARTIFACT_TYPE_OCI_IMAGE),
        STAGE_LEG_SERVICE,
        String(""),
    )
    _assert_row(
        String(REVISION_ROLE_PROBE),
        String(ARTIFACT_TYPE_OCI_IMAGE),
        STAGE_LEG_PROBE,
        String(""),
    )
    _assert_row(
        String(REVISION_ROLE_WEB_CONTENT),
        String(ARTIFACT_TYPE_CONTENT_BLOB),
        STAGE_LEG_WEB,
        String(""),
    )
    _assert_row(
        String(REVISION_ROLE_PYTHON_WHEEL),
        String(ARTIFACT_TYPE_PYTHON_WHEEL),
        STAGE_LEG_PACKAGE,
        String(".whl"),
    )
    _assert_row(
        String(REVISION_ROLE_CONDA_PACKAGE),
        String(ARTIFACT_TYPE_CONDA_PACKAGE),
        STAGE_LEG_PACKAGE,
        String(".conda"),
    )
    _assert_row(
        String(REVISION_ROLE_NPM_PACKAGE),
        String(ARTIFACT_TYPE_NPM_PACKAGE),
        STAGE_LEG_PACKAGE,
        String(".tgz"),
    )
    # The stamp tool's row: never staged or published. No writer records it (a
    # tool change moves N because the tool is in the input closure N is computed
    # over; its digest is recorded with the release's provenance).
    _assert_row(
        String(REVISION_ROLE_PACKAGE_STAMP_TOOL),
        String(ARTIFACT_TYPE_BUILD_TOOL),
        STAGE_LEG_NONE,
        String(""),
    )
    print("  test_every_row_is_keyed_and_carries_one_declared_leg: PASS")


def test_the_transports_partition_the_declared_legs() raises:
    assert_equal(
        STAGE_TRANSPORT_CONTENT_LEGS & STAGE_TRANSPORT_OCI_LEGS, 0, "content/oci"
    )
    assert_equal(
        STAGE_TRANSPORT_CONTENT_LEGS & STAGE_TRANSPORT_PACKAGE_LEGS,
        0,
        "content/package",
    )
    assert_equal(
        STAGE_TRANSPORT_OCI_LEGS & STAGE_TRANSPORT_PACKAGE_LEGS, 0, "oci/package"
    )
    assert_equal(
        STAGE_TRANSPORT_CONTENT_LEGS
        | STAGE_TRANSPORT_OCI_LEGS
        | STAGE_TRANSPORT_PACKAGE_LEGS,
        DECLARED_STAGE_LEGS,
        "every declared leg has exactly one transport",
    )
    assert_equal(
        STAGE_TRANSPORT_OCI_LEGS,
        STAGE_LEG_SERVICE | STAGE_LEG_PROBE,
        "SERVICE and PROBE share the OCI transport as two distinct bits",
    )
    # Every leg a row carries is declared, and every declared leg is carried by
    # some row — a declared leg nothing carries is dead vocabulary.
    var rows = artifact_type_rows()
    var table_legs = STAGE_LEG_NONE
    for i in range(len(rows)):
        table_legs |= rows[i].stage_leg
    assert_equal(
        table_legs,
        DECLARED_STAGE_LEGS,
        "the table's legs are exactly the declared legs",
    )
    print("  test_the_transports_partition_the_declared_legs: PASS")


def test_row_for_role_refuses_a_role_with_no_row() raises:
    var raised = False
    var msg = String("")
    try:
        _ = row_for_role(String("attachment"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a role with no row RAISES; it is never 'no leg'")
    assert_true(msg.find(String("'attachment'")) >= 0, "naming it: " + msg)
    assert_true(
        msg.find(known_roles_text()) >= 0,
        "and listing every role the table knows: " + msg,
    )
    # The empty role is a role with no row too, not a wildcard.
    var raised_empty = False
    try:
        _ = row_for_role(String(""))
    except:
        raised_empty = True
    assert_true(raised_empty, "the empty role has no row")
    print("  test_row_for_role_refuses_a_role_with_no_row: PASS")


def test_the_stageable_roles_are_derived_from_the_table() raises:
    var text = stageable_roles_text()
    var rows = artifact_type_rows()
    for i in range(len(rows)):
        var quoted = String("`") + rows[i].role + String("`")
        if rows[i].stage_leg == STAGE_LEG_NONE:
            assert_true(
                text.find(quoted) < 0,
                rows[i].role + " (leg NONE) is not stageable: " + text,
            )
        else:
            assert_true(
                text.find(quoted) >= 0,
                rows[i].role + " is listed as stageable: " + text,
            )
    print("  test_the_stageable_roles_are_derived_from_the_table: PASS")


def test_stage_leg_names_names_every_bit_and_an_undeclared_one() raises:
    assert_equal(stage_leg_names(STAGE_LEG_NONE), String("NONE"), "zero")
    assert_equal(
        stage_leg_names(DECLARED_STAGE_LEGS),
        String("WEB|SERVICE|PROBE|PACKAGE"),
        "every declared bit, in bit order",
    )
    assert_equal(
        stage_leg_names(STAGE_LEG_PROBE | 16),
        String("PROBE|UNDECLARED(16)"),
        "an undeclared bit is printed as its value, never dropped",
    )
    print("  test_stage_leg_names_names_every_bit_and_an_undeclared_one: PASS")


def test_package_version_puts_the_ordinal_in_the_patch_position() raises:
    assert_equal(package_version(String("1.1"), 7), String("1.1.7"), "1.1 + 7")
    assert_equal(package_version(String("1.2"), 8), String("1.2.8"), "1.2 + 8")
    var bad_n = List[Int]()
    bad_n.append(0)
    bad_n.append(-1)
    for i in range(len(bad_n)):
        var raised = False
        try:
            _ = package_version(String("1.1"), bad_n[i])
        except:
            raised = True
        assert_true(
            raised,
            "ordinal " + String(bad_n[i]) + " is refused: 0 is the unstamped"
            " SENTINEL, and no shipped file may carry it",
        )
    var bad_prefix = List[String]()
    bad_prefix.append(String(""))
    bad_prefix.append(String("1"))
    bad_prefix.append(String("1.1.0"))
    bad_prefix.append(String("a.1"))
    bad_prefix.append(String("1."))
    for i in range(len(bad_prefix)):
        var raised = False
        try:
            _ = package_version(bad_prefix[i], 7)
        except:
            raised = True
        assert_true(raised, "prefix '" + bad_prefix[i] + "' is not MAJOR.MINOR")
    print("  test_package_version_puts_the_ordinal_in_the_patch_position: PASS")


def test_a_two_subdir_conda_pair_keys_to_two_rows() raises:
    """The linux-64 and osx-arm64 files of one conda package may share a file
    name (the filename does not carry the platform), and must key to TWO rows."""
    var fname = String("example_pkg-1.1.7-hbd89045_0.conda")
    var linux = package_file_key(String(PACKAGE_SUBDIR_LINUX_64), fname)
    var mac = package_file_key(String(PACKAGE_SUBDIR_OSX_ARM64), fname)
    assert_true(
        linux != mac,
        "same file name, two subdirs -> two keys (else the second file is refused"
        " as 'differs', or read as the first)",
    )
    assert_equal(
        linux, String("linux-64/") + fname, "the key is <subdir>/<file_name>"
    )
    assert_equal(
        package_file_key(String(PACKAGE_SUBDIR_LINUX_64), fname),
        linux,
        "and it is a pure function of the pair",
    )
    assert_true(
        package_file_key(String(PACKAGE_SUBDIR_NOARCH), fname) != linux,
        "noarch is a third key",
    )
    assert_equal(len(package_subdirs()), 3, "the closed subdir vocabulary")
    var bad = List[String]()
    bad.append(String("win-64"))
    bad.append(String(""))
    for i in range(len(bad)):
        var raised = False
        try:
            _ = package_file_key(bad[i], fname)
        except:
            raised = True
        assert_true(raised, "subdir '" + bad[i] + "' is outside the vocabulary")
    var bad_names = List[String]()
    bad_names.append(String(""))
    bad_names.append(String("linux-64/x.conda"))
    for i in range(len(bad_names)):
        var raised = False
        try:
            _ = package_file_key(String(PACKAGE_SUBDIR_LINUX_64), bad_names[i])
        except:
            raised = True
        assert_true(
            raised,
            "file name '" + bad_names[i] + "' is refused (empty, or carries '/'"
            " and could collide with another pair)",
        )
    print("  test_a_two_subdir_conda_pair_keys_to_two_rows: PASS")


def main() raises:
    test_every_row_is_keyed_and_carries_one_declared_leg()
    test_the_transports_partition_the_declared_legs()
    test_row_for_role_refuses_a_role_with_no_row()
    test_the_stageable_roles_are_derived_from_the_table()
    test_stage_leg_names_names_every_bit_and_an_undeclared_one()
    test_package_version_puts_the_ordinal_in_the_patch_position()
    test_a_two_subdir_conda_pair_keys_to_two_rows()
    print("test_kci_revision_artifact_types: ALL PASS")
