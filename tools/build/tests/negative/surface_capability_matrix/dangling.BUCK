# Not a BUCK file of the repository: run_tests.sh (test 53) copies it to
# dangling/BUCK, builds tests//negative/surface_capability_matrix/dangling:dangling
# and deletes it. Loadable, this target would make every query over tests//...
# fail (the CI affected step's cquery among them).
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

# A row naming a target that does not exist: Buck2 refuses the graph.
surface_capability_matrix(
    name = "dangling",
    capabilities = SCM_CAPABILITIES,
    files = SCM_FILES,
    floor = SCM_FLOOR,
    grounding = SCM_GROUNDING,
    not_capabilities = SCM_NOT_CAPABILITIES,
    root = SCM_ROOT,
    rows = scm_set(SCM_MATRIX, "polars", "join_left", E2E + "polars_e2e:test_join_left"),
    surfaces = SCM_SURFACES,
)
