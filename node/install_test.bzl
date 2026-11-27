"""What //node:install_test installs and runs (node/BUCK), named here so that
its failing cases (tools/build/tests/negative/node) take the same files.

    INSTALL_TESTS     the test files node --test runs from the project
    INSTALL_DATA      {path in the project: file}: the tests and the fixtures
                      they read, exported by node/BUCK
    INSTALL_REGISTRY  the pinned tarballs npm resolves apache-arrow (the
                      peer), its dependencies and theirs to
    INSTALL_NODES     the Node.js lines the test runs on
"""

load("@komira//third_party/node:pins.bzl", "NPM", "NPM_INSTALL_ONLY")

INSTALL_TESTS = ["install.test.ts", "commonjs.test.cjs"]

INSTALL_FILES = INSTALL_TESTS + [
    "fixtures/sales.csv",
    "fixtures/sales.ndjson",
    "fixtures/sales.parquet",
]

INSTALL_DATA = {f: "komira//node:install/" + f for f in INSTALL_FILES}

# What npm installs for the peer dependency: apache-arrow and its
# `dependencies`, and @types/node's.
_ARROW_CLOSURE = ["apache-arrow", "flatbuffers", "json-with-bigint", "tslib", "@types/node", "undici-types"]

def _pinned_tarball(name):
    for p in NPM + NPM_INSTALL_ONLY:
        if p["name"] == name:
            return "komira//third_party/node:" + p["file"]
    fail("third_party/node/pins.bzl pins no npm package {}".format(name))

INSTALL_REGISTRY = [_pinned_tarball(n) for n in _ARROW_CLOSURE]

INSTALL_NODES = [
    "komira//third_party/node:node_22",
    "komira//third_party/node:node",
    "komira//third_party/node:node_26",
]
