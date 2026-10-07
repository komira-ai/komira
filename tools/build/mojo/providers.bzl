"""Providers shared by the Mojo rules."""

def _include_arg(pkg):
    # One `-I` per precompiled package: the directory that holds exactly that
    # `.mojoc`. The artifact itself becomes an input of the action.
    return cmd_args(pkg, format = "-I{}", parent = 1)

# The transitive closure of precompiled packages a consumer must see. The
# compiler needs the FULL closure on `-I`, not only direct deps.
MojoPkgTSet = transitive_set(args_projections = {"include": _include_arg})

MojoInfo = provider(fields = {
    # The definition `pkgs` was built with: this module as buck2 loaded it for
    # the BUILD file's cell. See mojo_pkg_children.
    "pkgs_def": provider_field(typing.Any, default = None),
    # C/C++ libraries (the prelude's MergedLinkInfo, e.g. from `cxx_library`)
    # that code in this package calls, with those of every package it depends
    # on: what a binary linking this package must also link. None when there
    # are none.
    "c_link": provider_field(typing.Any, default = None),
    # What the C of `c_link` is to libkomira_native.so.1, by the targets this
    # package and every package it depends on name in `deps` (a C library's
    # own C dependencies are not seen: the shared library's link fails if one
    # is missing from it). A struct of sorted label lists in the form of
    # tools/build/native/members.bzl, None when `c_link` is None:
    #   shared        declared `shared` (a NativeArchiveInfo)
    #   per_library   declared `per_library`
    #   undeclared    no declaration: a plain cxx_library, or a target outside
    #                 the komira cell
    # and `ships`, a list of (path in the package, archive) for the
    # `per_library` archives this package itself names in `deps`, which its
    # conda package carries (tools/build/package/conda.bzl).
    "native": provider_field(typing.Any, default = None),
    # The import names of the packages this one lists in `deps`, sorted: its
    # direct dependencies, which a published package names in its run
    # requirements (tools/build/package/conda.bzl). Required, not defaulted:
    # a rule that forgot it would publish a package with no dependencies.
    "direct": provider_field(typing.Any),
    # What the library's conda package is (tools/build/package/conda.bzl):
    # `conda_name` is the published name, None when the library opted out
    # (`conda = False`) or is not a mojo_library; `conda_refusal` is why the
    # package cannot be built (C outside libkomira_native.so.1, no tests, a
    # dependency with no package), None when it can. `direct_conda` maps the import name of each
    # direct dependency to a struct(name, refusal) of the same two facts, which
    # is how a package names its requirements by their PUBLISHED names.
    "conda_name": provider_field(typing.Any, default = None),
    "conda_refusal": provider_field(typing.Any, default = None),
    "direct_conda": provider_field(typing.Any, default = {}),
    # The sonames the library opens at run time (`dlopen`, sorted), each with
    # the conda requirement of the package that ships it
    # (tools/build/package/system_libs.bzl): a list of (soname, requirement).
    "dlopen": provider_field(typing.Any, default = []),
    "import_name": provider_field(str),
    "pkgs": provider_field(typing.Any),  # MojoPkgTSet
    # The package's README.md (the source artifact), None without one. Its
    # conda package installs it at share/doc/<conda name>/README.md
    # (tools/build/package/conda.bzl).
    "readme": provider_field(typing.Any, default = None),
})

MojoToolchainInfo = provider(fields = {
    # Static busybox: the shell and file utilities every action uses.
    "busybox": provider_field(typing.Any),
    # Directory: the unpacked compiler closure (bin/mojo, lib/, share/max,
    # CLOSURE_MANIFEST).
    "compiler": provider_field(typing.Any),
    # Directory: what the compile's link step runs. On linux, the unpacked
    # zig distribution (the C link driver); on macOS, a `mojo_darwin_link`
    # (the cc shim and the host identity the execution platform promises).
    "link": provider_field(typing.Any),
    # The link target: a zig -target triple on linux, the deployment target
    # (MACOSX_DEPLOYMENT_TARGET) on macOS.
    "cc_target": provider_field(str),
    # `--target-cpu` for every compile. Pinned, because the compiler's default
    # is the CPU of the machine the action runs on, which is not part of the
    # action key.
    "target_cpu": provider_field(str),
    "wrapper": provider_field(typing.Any),
    # The compile watchdog of the wrapper (mojo_wrapper.sh): kill a compile
    # whose process tree used no CPU for this long (0: off), sampling every
    # `watchdog_sample_secs`. None where the wrapper has no watchdog.
    "watchdog_idle_secs": provider_field(typing.Any, default = None),
    "watchdog_sample_secs": provider_field(typing.Any, default = None),
    "gate_runner": provider_field(typing.Any),
    "run_check": provider_field(typing.Any),
    "launcher": provider_field(typing.Any),
    # Directory: only the shared libraries a built binary loads (a
    # `mojo_runtime`). A runnable binary carries a copy of it as lib/.
    "runtime": provider_field(typing.Any),
    # The operating system the compiled code runs on: "linux" or "darwin".
    # Rules that differ by platform (mojo_shared_lib: .so or .dylib, the link
    # flags that name and limit its symbols) read it here, so the target
    # platform is decided by the toolchain, never by a second attribute.
    "os": provider_field(str, default = "linux"),
})

# A built binary that starts on its own: `run_dir` holds the binary and lib/,
# its runtime libraries, and `command` runs it from there with no launcher.
MojoRunnableInfo = provider(fields = {
    "binary": provider_field(str),  # the binary's file name inside run_dir
    "command": provider_field(typing.Any),  # cmd_args
    "run_dir": provider_field(typing.Any),  # artifact (directory)
})

# A mojo_binary's program as a shared library, for packaging (komira//tools/build/package).
MojoProgramInfo = provider(fields = {
    "name": provider_field(str),  # the program's name: bin/<name>, lib<name>.so
    "shared": provider_field(typing.Any),  # artifact lib<name>.so
    "runtime": provider_field(typing.Any),  # artifact: directory of runtime libraries
    "target_cpu": provider_field(str),  # the CPU the program was compiled for
})


def mojo_pkg_children(ctx, infos):
    """The `pkgs` of each MojoInfo in `infos`, as children of a MojoPkgTSet of this module.

    buck2 keys a .bzl module by the cell of the BUILD file that loads it, so a
    target in a consuming repository's own cell and a target in the `komira`
    cell get two MojoPkgTSet definitions, and a transitive set refuses
    children of another definition. The packages of a closure built with
    another definition are re-wrapped here as a chain of this definition, in
    their original order and without repeating one already taken from an
    earlier dependency; a closure built with this definition is passed
    through, so a build where every package is in one cell creates exactly the
    sets it always did.
    """
    children = []
    seen = {}
    for info in infos:
        if info.pkgs_def == MojoPkgTSet:
            children.append(info.pkgs)
            continue
        pkgs = []
        for pkg in info.pkgs.traverse():
            key = str(pkg)
            if key not in seen:
                seen[key] = True
                pkgs.append(pkg)
        chain = None
        for pkg in reversed(pkgs):
            chain = ctx.actions.tset(MojoPkgTSet, value = pkg, children = [chain] if chain else [])
        if chain:
            children.append(chain)
    return children

# The test files a target runs as tests, as the build graph resolved them: a
# mojo_library's `test_srcs` (each built and run alone) and a mojo_test's
# `main` (its binary runs `main` only: the other `srcs` are modules `main`
# imports). The source artifacts themselves, not paths: the test_weld lint
# (tools/build/lint/test_weld.bzl) asks Buck2 where each file is, so an entry
# naming a file of another package (a label, e.g. an export_file) counts for
# that file and never for a same-named one of this package. A generated
# source (a target's output) is no file of the tree and is left out. A test
# counts as welded by what the rule received, however the BUCK file spelt it.
WeldedTestsInfo = provider(fields = {
    "srcs": provider_field(list[Artifact]),
})

def welded_tests_info(srcs):
    """WeldedTestsInfo of `srcs`, the test source artifacts a target runs."""
    return WeldedTestsInfo(srcs = [s for s in srcs if s.is_source])
