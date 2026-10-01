# =============================================================================
# komira_deploy_bundle/tests/test_matrix.mojo
#   — the NEUTRAL device/capability MATRIX authoring block: parse + fail-closed
#     synth-time validation.
# =============================================================================
#
# Scope = SCHEMA + PARSE + VALIDATE ONLY (NO pipeline cell fan).
# These tests pin:
#   (1) a `matrices {}` block (a NATIVE cell w/ from_build + a WEB cell w/ browser)
#       PARSES and round-trips every field, and a `PipelineStep.matrix_ref` parses;
#   (2) `validate_bundle` PASSES a well-formed matrix (zero errors);
#   (3) `validate_bundle` FAILS-CLOSED on
#         (a) a `matrix_ref` naming no declared Matrix,
#         (b) a NATIVE cell whose `from_build` names no declared BuildTarget,
#         (c) a cell that is NEITHER native nor web (and, bonus, one that is BOTH).
#
# Encapsulation: pure parse + validate + field/list asserts. Mojo 1.0.0b2.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_deploy_bundle.parser import parse_bundle
from komira_deploy_bundle.validate import validate_bundle


def _errs(text: String) raises -> List[String]:
    return validate_bundle(parse_bundle(text))


def _any_contains(errs: List[String], needle: String) -> Bool:
    for ref e in errs:
        if e.find(needle) >= 0:
            return True
    return False


# A well-formed bundle: an API kind with a `desktop` build target, a `support`
# matrix carrying a NATIVE cell (from_build -> "desktop") + a WEB cell (browser),
# and a BUILD step that fans over the matrix via `matrix_ref: "support"`.
def _good_bundle() -> String:
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        "  cell {\n"
        '    name: "mac-arm64"\n'
        '    os: "macos"\n'
        '    arch: "arm64"\n'
        '    artifact_kind: "dmg"\n'
        '    os_version_min: "13.0"\n'
        '    os_version_max: "15.9"\n'
        '    from_build: "desktop"\n'
        "  }\n"
        "  cell {\n"
        '    name: "web-chromium"\n'
        '    os: "web"\n'
        '    browser: "chromium"\n'
        "  }\n"
        "}\n"
        "pipeline {\n"
        '  steps { step_kind: STEP_KIND_BUILD envs: "dev" matrix_ref: "support" }\n'
        "}\n"
    )


def test_matrix_parses_and_round_trips_fields() raises:
    """The `matrices {}` block + `matrix_ref` parse into the generated struct and
    round-trip every authored field."""
    var b = parse_bundle(_good_bundle())

    # one matrix, named, with two cells.
    assert_equal(len(b.matrices), 1, "one matrix parsed")
    ref mx = b.matrices[0]
    assert_equal(mx.name, String("support"), "matrix name")
    assert_equal(len(mx.cell), 2, "two cells")

    # cell[0] — the NATIVE cell (from_build set, browser empty).
    ref native = mx.cell[0]
    assert_equal(native.name, String("mac-arm64"), "native cell name")
    assert_equal(native.os, String("macos"), "native cell os")
    assert_equal(native.arch, String("arm64"), "native cell arch")
    assert_equal(native.artifact_kind, String("dmg"), "native cell artifact_kind")
    assert_equal(native.os_version_min, String("13.0"), "native cell os_version_min")
    assert_equal(native.os_version_max, String("15.9"), "native cell os_version_max")
    assert_equal(native.from_build, String("desktop"), "native cell from_build")
    assert_equal(native.browser, String(""), "native cell has no browser")

    # cell[1] — the WEB cell (browser set, from_build empty).
    ref web = mx.cell[1]
    assert_equal(web.name, String("web-chromium"), "web cell name")
    assert_equal(web.os, String("web"), "web cell os")
    assert_equal(web.browser, String("chromium"), "web cell browser")
    assert_equal(web.from_build, String(""), "web cell has no from_build")

    # the pipeline step's matrix_ref round-trips.
    assert_true(b.pipeline.__bool__(), "pipeline parsed")
    ref p = b.pipeline.value()
    assert_equal(len(p.steps), 1, "one step")
    assert_equal(p.steps[0].matrix_ref, String("support"), "step matrix_ref")

    print("  test_matrix_parses_and_round_trips_fields: PASS")


def test_well_formed_matrix_validates_clean() raises:
    """A well-formed matrix (native cell resolves, web cell has a browser, the
    step's matrix_ref names the declared matrix) produces ZERO errors."""
    assert_equal(
        len(_errs(_good_bundle())), 0, "a well-formed matrix bundle is valid"
    )
    print("  test_well_formed_matrix_validates_clean: PASS")


def test_matrix_ref_naming_no_matrix_fails_closed() raises:
    """(a) A `matrix_ref` that names no declared Matrix is a fail-closed error."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "mac" os: "macos" from_build: "desktop" }\n'
        "}\n"
        "pipeline {\n"
        '  steps { step_kind: STEP_KIND_BUILD envs: "dev" matrix_ref: "nope" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("matrix_ref 'nope' does not name a matrix")),
        "dangling matrix_ref flagged",
    )
    print("  test_matrix_ref_naming_no_matrix_fails_closed: PASS")


def test_native_cell_from_build_naming_no_target_fails_closed() raises:
    """(b) A NATIVE cell whose `from_build` names no declared BuildTarget is a
    fail-closed error (mirrors the ImageRef.from_build -> BuildTarget check)."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "mac" os: "macos" from_build: "ghost" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("from_build 'ghost' does not name a build target")),
        "dangling cell from_build flagged",
    )
    print("  test_native_cell_from_build_naming_no_target_fails_closed: PASS")


def test_cell_neither_native_nor_web_fails_closed() raises:
    """(c) A cell that is NEITHER native (no from_build) nor web (no browser) is a
    fail-closed error."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "empty" os: "macos" arch: "arm64" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("it is neither")),
        "a neither-native-nor-web cell flagged",
    )
    print("  test_cell_neither_native_nor_web_fails_closed: PASS")


def test_cell_both_native_and_web_fails_closed() raises:
    """A cell that is BOTH native (from_build) AND web (browser) is a fail-closed
    error — the native-XOR-web invariant."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "both" from_build: "desktop" browser: "chromium" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("never both")),
        "a both-native-and-web cell flagged",
    )
    print("  test_cell_both_native_and_web_fails_closed: PASS")


# A well-formed prefix (kind/name/build/spec/waves) that every negative case
# below reuses — so only the matrices{} block under test carries the fault.
def _pfx() -> String:
    return String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
    )


def test_duplicate_matrix_name_fails_closed() raises:
    """(d) Two matrices with the same name is a fail-closed error (the
    matrix-name-uniqueness path — implemented, now pinned)."""
    var text = (
        _pfx()
        + String(
            'matrices { name: "support" cell { name: "a" from_build: "desktop" } }\n'
            'matrices { name: "support" cell { name: "b" from_build: "desktop" } }\n'
        )
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("duplicate matrix name 'support'")),
        "duplicate matrix name flagged",
    )
    print("  test_duplicate_matrix_name_fails_closed: PASS")


def test_duplicate_cell_name_fails_closed() raises:
    """A cell name duplicated WITHIN a matrix is a fail-closed error (unique per
    Matrix — a verdict-to-cell ambiguity in the cell fan otherwise)."""
    var text = (
        _pfx()
        + String(
            "matrices {\n"
            '  name: "support"\n'
            '  cell { name: "dup" os: "macos" from_build: "desktop" }\n'
            '  cell { name: "dup" os: "windows" from_build: "desktop" }\n'
            "}\n"
        )
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("duplicate cell name 'dup'")),
        "duplicate cell name flagged",
    )
    print("  test_duplicate_cell_name_fails_closed: PASS")


def test_zero_cell_matrix_fails_closed() raises:
    """A declared matrix with NO cells is a fail-closed error (a matrix_ref to it
    would silently fan to zero jobs)."""
    var text = _pfx() + String('matrices { name: "empty" }\n')
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("must declare at least one 'cell'")),
        "zero-cell matrix flagged",
    )
    print("  test_zero_cell_matrix_fails_closed: PASS")


def test_empty_cell_name_fails_closed() raises:
    """A cell with an empty `name` is a fail-closed error."""
    var text = (
        _pfx()
        + String(
            'matrices { name: "support" cell { os: "macos" from_build: "desktop" } }\n'
        )
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("'name' is required (a cell name)")),
        "empty cell name flagged",
    )
    print("  test_empty_cell_name_fails_closed: PASS")


def test_malformed_os_version_fails_closed() raises:
    """A non-dotted-numeric os_version_min is a fail-closed error."""
    var text = (
        _pfx()
        + String(
            "matrices {\n"
            '  name: "support"\n'
            '  cell { name: "m" from_build: "desktop" os_version_min: "13.x" }\n'
            "}\n"
        )
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("is not a dotted-numeric version")),
        "malformed os_version flagged",
    )
    print("  test_malformed_os_version_fails_closed: PASS")


def test_os_version_min_gt_max_fails_closed() raises:
    """os_version_min > os_version_max (component-wise) is a fail-closed error."""
    var text = (
        _pfx()
        + String(
            "matrices {\n"
            '  name: "support"\n'
            "  cell {\n"
            '    name: "m"\n'
            '    from_build: "desktop"\n'
            '    os_version_min: "15.0"\n'
            '    os_version_max: "13.0"\n'
            "  }\n"
            "}\n"
        )
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("must be <= os_version_max")),
        "inverted os_version range flagged",
    )
    print("  test_os_version_min_gt_max_fails_closed: PASS")


# =============================================================================
# The TYPED-ARTIFACT matrix-dims constraint: the typed AppKinds (DESKTOP/MOBILE/LIBRARY) CONSTRAIN
# the valid OS of their NATIVE cells (fail-closed at synth). DESKTOP → {macos,
# windows, linux/ubuntu}; MOBILE → {ios, android}; LIBRARY → any; the existing
# deployable-service kinds (API, …) are UNCONSTRAINED (behavior-identical). WEB
# cells (browser set) are orthogonal — never constrained by app-kind.
# =============================================================================


def test_desktop_valid_native_cells_pass() raises:
    """A DESKTOP_APPLICATION whose NATIVE cells target {macos, windows, linux,
    ubuntu} (both linux spellings) plus a WEB cell VALIDATES CLEAN — the typed
    constraint admits the app's OS family, and WEB cells are orthogonal."""
    var text = String(
        "kind: APP_KIND_DESKTOP_APPLICATION\n"
        'name: "desk"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "mac"    os: "macos"   arch: "arm64"  from_build: "desktop" }\n'
        '  cell { name: "win"    os: "windows" arch: "x86_64" from_build: "desktop" }\n'
        '  cell { name: "lin"    os: "linux"   arch: "x86_64" from_build: "desktop" }\n'
        '  cell { name: "ubu"    os: "ubuntu"  arch: "x86_64" from_build: "desktop" }\n'
        '  cell { name: "webc"   os: "web"     browser: "chromium" }\n'
        "}\n"
    )
    assert_equal(len(_errs(text)), 0, "a DESKTOP app with in-family native cells is valid")
    print("  test_desktop_valid_native_cells_pass: PASS")


def test_mobile_valid_native_cells_pass() raises:
    """A MOBILE_APPLICATION whose NATIVE cells target {ios, android} VALIDATES
    CLEAN."""
    var text = String(
        "kind: APP_KIND_MOBILE_APPLICATION\n"
        'name: "mob"\n'
        'build { name: "app" dockerfile: "Dockerfile.app" }\n'
        'spec { image { from_build: "app" } }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "ios" os: "ios"     from_build: "app" }\n'
        '  cell { name: "and" os: "android" from_build: "app" }\n'
        "}\n"
    )
    assert_equal(len(_errs(text)), 0, "a MOBILE app with ios/android native cells is valid")
    print("  test_mobile_valid_native_cells_pass: PASS")


def test_mobile_with_linux_native_cell_fails_closed() raises:
    """A MOBILE_APPLICATION with a `linux` NATIVE cell is a device-farm MISROUTE
    — fail-closed at synth with a clear message naming the app-kind + allowed
    set."""
    var text = String(
        "kind: APP_KIND_MOBILE_APPLICATION\n"
        'name: "mob"\n'
        'build { name: "app" dockerfile: "Dockerfile.app" }\n'
        'spec { image { from_build: "app" } }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "bad" os: "linux" from_build: "app" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("os 'linux' is not valid for an")),
        "a MOBILE app's linux native cell is fail-closed",
    )
    assert_true(
        _any_contains(errs, String("ios, android")),
        "the message lists the allowed mobile OS set",
    )
    print("  test_mobile_with_linux_native_cell_fails_closed: PASS")


def test_typed_native_cell_missing_os_fails_closed() raises:
    """A typed (DESKTOP/MOBILE) app's NATIVE cell with NO `os` is fail-closed —
    an unspecified-os native cell is a misroute (dispatches to any device)."""
    var text = String(
        "kind: APP_KIND_MOBILE_APPLICATION\n"
        'name: "mob"\n'
        'build { name: "app" dockerfile: "Dockerfile.app" }\n'
        'spec { image { from_build: "app" } }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "noos" from_build: "app" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        _any_contains(errs, String("must declare an 'os' in {ios, android}")),
        "an unspecified-os mobile native cell is fail-closed",
    )
    print("  test_typed_native_cell_missing_os_fails_closed: PASS")


def test_library_any_os_native_cells_pass() raises:
    """A LIBRARY app's NATIVE cells may target ANY os (no per-kind constraint) —
    macos, linux, AND ios all validate clean."""
    var text = String(
        "kind: APP_KIND_LIBRARY\n"
        'name: "lib"\n'
        'build { name: "lib" dockerfile: "Dockerfile.lib" }\n'
        'spec { image { from_build: "lib" } }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "a" os: "macos" from_build: "lib" }\n'
        '  cell { name: "b" os: "linux" from_build: "lib" }\n'
        '  cell { name: "c" os: "ios"   from_build: "lib" }\n'
        "}\n"
    )
    assert_equal(len(_errs(text)), 0, "a LIBRARY app admits any native-cell os")
    print("  test_library_any_os_native_cells_pass: PASS")


def test_existing_kind_unconstrained_by_app_kind_dims() raises:
    """An existing deployable-service kind (API) is UNAFFECTED by the typed
    constraint — a native cell with an `android` os (which a MOBILE app would
    reject) is accepted, and the bundle validates clean (migration-safety)."""
    var text = String(
        "kind: APP_KIND_API\n"
        'name: "svc"\n'
        'build { name: "desktop" dockerfile: "Dockerfile.desktop" }\n'
        'spec { image { from_build: "desktop" } port: 8080 }\n'
        'waves { env: "dev" }\n'
        "matrices {\n"
        '  name: "support"\n'
        '  cell { name: "x" os: "android" from_build: "desktop" }\n'
        "}\n"
    )
    var errs = _errs(text)
    assert_true(
        not _any_contains(errs, String("is not valid for an")),
        "an API bundle is not subject to the app-kind matrix-dims constraint",
    )
    assert_equal(len(errs), 0, "the API bundle validates clean (unconstrained)")
    print("  test_existing_kind_unconstrained_by_app_kind_dims: PASS")


def main() raises:
    test_matrix_parses_and_round_trips_fields()
    test_well_formed_matrix_validates_clean()
    test_matrix_ref_naming_no_matrix_fails_closed()
    test_native_cell_from_build_naming_no_target_fails_closed()
    test_cell_neither_native_nor_web_fails_closed()
    test_cell_both_native_and_web_fails_closed()
    # completeness gaps
    test_duplicate_matrix_name_fails_closed()
    test_duplicate_cell_name_fails_closed()
    test_zero_cell_matrix_fails_closed()
    test_empty_cell_name_fails_closed()
    test_malformed_os_version_fails_closed()
    test_os_version_min_gt_max_fails_closed()
    # typed-artifact matrix-dims constraint
    test_desktop_valid_native_cells_pass()
    test_mobile_valid_native_cells_pass()
    test_mobile_with_linux_native_cell_fails_closed()
    test_typed_native_cell_missing_os_fails_closed()
    test_library_any_os_native_cells_pass()
    test_existing_kind_unconstrained_by_app_kind_dims()
    print("PASS test_matrix")
