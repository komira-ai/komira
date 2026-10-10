# Not a BUCK file of the repository: node_tests.sh (test 54) copies it to
# visibility/BUCK (and visibility.js to visibility/pass.js), builds
# tests//negative/node/visibility:node_not_visible and deletes both. It fails
# analysis by design, so loadable it would make every query over tests//...
# fail (the CI affected step's reverse-dependency cquery among them).
load("@komira//tools/build/node:defs.bzl", "node_test")

# Test 54's visibility guard (node_tests.sh requires "is not visible"): the
# pinned runtime is test-only, visible only to third_party/node/BUCK's
# _TEST_ONLY packages and the planted defects of tests//negative/node itself.
# This subpackage is neither, so naming the runtime must fail to build; it
# goes green if the runtime is made visible to anything wider.
node_test(
    name = "node_not_visible",
    src = "pass.js",
    node = "komira//third_party/node:node",
)
