# Not a BUCK file of the repository: run_tests.sh (test 53) copies it to
# incompatible/BUCK, builds tests//negative/surface_capability_matrix/incompatible:
# and deletes it. Loadable, this target would make every cquery over tests//...
# fail (the CI affected step's among them).
load("@komira//tools/build/lint:surface_capability_matrix.bzl", "surface_capability_matrix")
load(
    "//functional/surface_capability_matrix:fixture.bzl",
    "E2E",
    "SCM_CAPABILITIES",
    "SCM_FILES",
    "SCM_FLOOR",
    "SCM_GROUNDING",
    "SCM_MATRIX",
    "SCM_NOT_CAPABILITIES",
    "SCM_ROOT",
    "SCM_SURFACES",
    "scm_set",
)

# Test 53, negative incompatible, alone in its package so that run_tests.sh
# builds it by a package pattern (`.../incompatible:`), as `//...` and `//:`
# reach the root lint: a row naming a test incompatible with the lint's
# platform (pandas_e2e:test_mac, macOS only) must fail the build, not drop
# the lint out of the pattern silently.
surface_capability_matrix(
    name = "incompatible",
    capabilities = SCM_CAPABILITIES,
    files = SCM_FILES,
    floor = SCM_FLOOR,
    grounding = SCM_GROUNDING,
    not_capabilities = SCM_NOT_CAPABILITIES,
    root = SCM_ROOT,
    rows = scm_set(SCM_MATRIX, "pandas", "errors", E2E + "pandas_e2e:test_mac"),
    surfaces = SCM_SURFACES,
)
