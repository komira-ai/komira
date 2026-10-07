"""`test_deps` of mojo_library (defs.bzl).

Mojo packages a library's welded tests are compiled against besides the
library and its `deps`: a test-support package, such as a fake service that
several of the tests share. A gated test is built from its one file, so
without this the only way for two tests to share code is to put it in the
library or in a dep of it, which ships it. A `test_deps` package reaches the
tests only (their compile and link, and their coverage builds); it is not
in the library's compile, its package, its MojoInfo, its README examples'
closure or its conda package. It may not depend on the library (buck2
refuses the cycle).
"""

load("@prelude//linking:link_info.bzl", "create_merged_link_info_for_propagation")
load(":providers.bzl", "MojoInfo", "mojo_pkg_children")

def check_test_deps(ctx):
    """Refuses a `test_deps` entry that is not a Mojo package, or that is also in `deps`."""
    deps = {str(d.label.raw_target()): True for d in ctx.attrs.deps}
    for d in ctx.attrs.test_deps:
        if MojoInfo not in d:
            fail("{}: test_deps entry {} is not a Mojo package (a mojo_library); test_deps holds test-support packages only".format(ctx.label.raw_target(), d.label.raw_target()))
        if str(d.label.raw_target()) in deps:
            fail("{}: {} is in both deps and test_deps; a test already sees every dep, so name it once, in deps".format(ctx.label.raw_target(), d.label.raw_target()))

def test_closure(ctx, ungated_tset):
    """The closure each welded test is compiled against: the ungated package
    and its deps, then each `test_deps` package's closure."""
    if not ctx.attrs.test_deps:
        return [ungated_tset]
    return [ungated_tset] + mojo_pkg_children(ctx, [d[MojoInfo] for d in ctx.attrs.test_deps])

def test_c_link(ctx, c_link):
    """`c_link` plus the C libraries of each `test_deps` package's closure."""
    infos = [d[MojoInfo].c_link for d in ctx.attrs.test_deps if d[MojoInfo].c_link != None]
    if not infos:
        return c_link
    return create_merged_link_info_for_propagation(ctx, ([c_link] if c_link != None else []) + infos)
