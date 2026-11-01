"""The cases of tests//negative/mopm_artifacts (its BUCK file says what each must refuse)."""

load("@komira//release:mopm_artifacts.bzl", "mopm_artifacts")
load("@komira//tools/build/lint:doc_tree.bzl", "package_docs")

_LIBC_ARCHIVE = "komira//src/komira_libc:native_komira_libc_posix"

def mopm_artifacts_case():
    # Every package declares its doc_tree (tests//:doc_tree collects it),
    # with or without a case.
    package_docs()
    case = read_config("mopm_artifacts", "case", "")
    if case == "wrong_id":
        mopm_artifacts(name = "artifacts", packages = ["komira_libc"], natives = {"komira_libc": {"komira_libc_posx": _LIBC_ARCHIVE}})
    elif case == "missing_entry":
        mopm_artifacts(name = "artifacts", packages = ["komira_libc"])
    elif case:
        fail("mopm_artifacts.case: unknown case `{}`".format(case))
