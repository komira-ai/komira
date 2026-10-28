"""The cases of tests//negative/adopt_deps (its BUCK file says what each must refuse)."""

load("@komira//tools/build/lint:doc_tree.bzl", "package_docs")
load("@komira//tools/build/mojo:adopt.bzl", "mojo_adopted_library")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")
load("@komira//tools/build/mojo:native_facts.bzl", "native_refusal_test")

# komira_resources is built from one sibling package, komira_runtime_paths ([dependencies] of its mopm.toml).
_LIB = "komira//src/komira_resources:lib"
_TEST = "komira//src/komira_resources:test"
_RUNTIME_PATHS = "komira//src/komira_runtime_paths:komira_runtime_paths"
_JSON = "komira//src/komira_json:komira_json"

# The `native_*` cases adopt komira_metrics' `:lib`, which links the C of its own (`libkomira_metrics_ea_flag.a`,
# so its `MojoNativeArchiveInfo` gives the adopted label a `c_link`), and name the library's closure.
_METRICS_LIB = "komira//src/komira_metrics:lib"
_METRICS_TEST = "komira//src/komira_metrics:test"
_METRICS_DEPS = [
    "komira//src/komira_atomic_alias:komira_atomic_alias",
    "komira//src/komira_clock:komira_clock",
    "komira//src/komira_collections:komira_collections",
    "komira//src/komira_hash:komira_hash",
    "komira//src/komira_name_registry:komira_name_registry",
]
_C_FLAG = "komira//src/komira_metrics:komira_metrics_ea_flag"

# The `native_*` cases: an adopted library that links C of its own (`c_deps`), a library that depends on it, and
# the check that the dependent's closure ships every C library it links (native_facts.bzl, `native_refusal_test`).
# `native_static` is whether the adopted library ships its C as a static archive; `unshipped` is what the check
# states the closure still links with no owner.
_NATIVE_CASES = {
    "native_unshipped": (False, []),
    "native_unshipped_stated": (False, [_C_FLAG]),
    "native_static": (True, []),
}

def _native_case(case):
    static, unshipped = _NATIVE_CASES[case]
    mojo_adopted_library(
        name = "adopted",
        c_deps = [_C_FLAG],
        deps = _METRICS_DEPS,
        import_name = "komira_metrics",
        lib = _METRICS_LIB,
        native_static = static,
        srcs = ["komira_resources/__init__.mojo"],
        test_runs = _METRICS_TEST,
        test_srcs = [],
    )
    mojo_library(
        name = "native_user",
        srcs = ["native_user/__init__.mojo"],
        test_srcs = ["native_user/tests/test_native_user.mojo"],
        deps = [":adopted"],
    )
    native_refusal_test(
        name = "native_closure",
        lib = ":native_user",
        unshipped = unshipped,
    )

def adopt_deps_case():
    # Every package declares its doc_tree (tests//:doc_tree collects it), with or without a case.
    package_docs()
    case = read_config("adopt_deps", "case", "")
    if case == "agree":
        deps = [_RUNTIME_PATHS]
    elif case == "missing":
        deps = []
    elif case == "extra":
        deps = [_RUNTIME_PATHS, _JSON]
    elif case in _NATIVE_CASES:
        _native_case(case)
        return
    elif case:
        fail("adopt_deps.case: unknown case `{}`".format(case))
    else:
        return
    mojo_adopted_library(
        name = "adopted",
        deps = deps,
        import_name = "komira_resources",
        lib = _LIB,
        srcs = ["komira_resources/__init__.mojo"],
        test_runs = _TEST,
        test_srcs = [],
    )
