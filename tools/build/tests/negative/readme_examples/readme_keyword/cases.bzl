"""The cases of tests//negative/readme_examples/readme_keyword (its BUCK file says what each must refuse)."""

load("@komira//tools/build/lint:doc_tree.bzl", "package_docs")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library")

def readme_keyword_case():
    # Every package declares its doc_tree (tests//:doc_tree collects it),
    # with or without a case.
    package_docs()
    case = read_config("readme_keyword", "case", "")
    if case == "true_without_readme":
        mojo_library(name = "kw", srcs = ["__init__.mojo"], conda = False, readme = True)
    elif case == "not_bool":
        mojo_library(name = "kw", srcs = ["__init__.mojo"], conda = False, readme = "README.md")
    elif case:
        fail("readme_keyword.case: unknown case `{}`".format(case))
