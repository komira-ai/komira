"""The cases of tests//negative/adopt_system_libs (its BUCK file says what each must do)."""

load("@buildrules//rules/core:pinned_file.bzl", "pinned_file")
load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load("@buildrules//rules/mojo:system_libs.bzl", "mojo_system_lib_rule")
load("@komira//tools/build/lint:doc_tree.bzl", "package_docs")
load("@komira//tools/build/mojo:adopt.bzl", "mojo_adopted_library")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library", "mojo_test")
load(":fixture.bzl", "pinned_lib")

def adopt_system_libs_case():
    # Every package declares its doc_tree (tests//:doc_tree collects it), with or without a case.
    package_docs()
    case = read_config("adopt_system_libs", "case", "")
    if case not in ["pinned", "unpinned"]:
        if case:
            fail("adopt_system_libs.case: unknown case `{}`".format(case))
        return

    # The files conda-forge ships for SQLite and the library it needs, sha256-pinned as buildrules' own stand-in pins them.
    pinned_file(
        name = "libsqlite.conda",
        url = "https://conda.anaconda.org/conda-forge/linux-64/libsqlite-3.54.1-h0737f62_101.conda",
        sha256 = "c294029f893d05286f1061bbab85b820f1eea73dd859af4bcc619197bcc34810",
        size_bytes = 980491,
    )
    pinned_file(
        name = "libzlib.conda",
        url = "https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.2-h25fd6f3_3.conda",
        sha256 = "eb8a0db0aa570124f7d2a93d7c7f596e3390df5e047818d873baad32985fc736",
        size_bytes = 63713,
    )
    mojo_system_lib_rule(name = "libsqlite", archive = ":libsqlite.conda", package = "libsqlite", exec_compatible_with = LINUX_X86_64)
    mojo_system_lib_rule(name = "libzlib", archive = ":libzlib.conda", package = "libzlib", exec_compatible_with = LINUX_X86_64)

    # The package that opens SQLite by its bare name, built here by komira's rules (its own test does not call the function).
    mojo_library(
        name = "codec",
        srcs = ["syslib_codec/__init__.mojo"],
        test_srcs = ["tests/test_codec.mojo"],
        import_name = "syslib_codec",
        conda = False,
        readme = False,
    )

    # What the gated `:lib` of a package that pins the two libraries is: the library's file and, in the `pinned` case, the directories. The `unpinned` case is
    # the same package whose `:lib` forgot its pins.
    pinned_lib(
        name = "codec_lib",
        lib = ":codec",
        system_libs = [":libsqlite", ":libzlib"] if case == "pinned" else [],
    )
    mojo_adopted_library(
        name = "adopted",
        import_name = "syslib_codec",
        lib = ":codec_lib",
        srcs = ["syslib_codec/__init__.mojo"],
        test_runs = ":codec[tests]",
        test_srcs = ["tests/test_codec.mojo"],
    )

    # The old-rule dependent: its welded test calls the codec, so its run (and its coverage runs) must find libsqlite3.so.0.
    mojo_library(
        name = "consumer",
        srcs = ["syslib_consumer/__init__.mojo"],
        test_srcs = ["tests/test_consumer.mojo"],
        deps = [":adopted"],
        import_name = "syslib_consumer",
        conda = False,
        readme = False,
    )

    # A `mojo_test` that depends on the adopted package: `buck2 test` runs it through the gate, which is given the same directories.
    mojo_test(
        name = "program_test",
        main = "tests/test_program.mojo",
        srcs = ["tests/test_program.mojo"],
        deps = [":adopted"],
    )
