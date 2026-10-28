"""The cases of tests//negative/adopt_deps (its BUCK file says what each must refuse)."""

load("@komira//tools/build/lint:doc_tree.bzl", "package_docs")
load("@komira//tools/build/mojo:adopt.bzl", "mojo_adopted_library")

# komira_resources is built from one sibling package, komira_runtime_paths ([dependencies] of its mopm.toml).
_LIB = "komira//src/komira_resources:lib"
_TEST = "komira//src/komira_resources:test"
_RUNTIME_PATHS = "komira//src/komira_runtime_paths:komira_runtime_paths"
_JSON = "komira//src/komira_json:komira_json"

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
