"""One fixture library of tests//negative/conda_pkgs."""

load("@komira//tools/build/mojo:defs.bzl", "mojo_library")

def neg_lib(name, deps = [], tests = True):
    mojo_library(
        name = name,
        srcs = ["{}/__init__.mojo".format(name)],
        test_srcs = ["{0}/tests/test_{0}.mojo".format(name)] if tests else [],
        deps = deps,
        visibility = ["PUBLIC"],
    )
