"""The targets of tests//negative/adopt_system_libs (its BUCK file says what each must do)."""

load("@buildrules//rules/core:pinned_file.bzl", "pinned_file")
load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load("@buildrules//rules/mojo:system_libs.bzl", "mojo_system_lib_rule")
load("@komira//tools/build/lint:doc_tree.bzl", "package_docs")
load("@komira//tools/build/mojo:adopt.bzl", "mojo_adopted_library")
load("@komira//tools/build/mojo:defs.bzl", "mojo_library", "mojo_shared_lib", "mojo_test")
load(":fixture.bzl", "pinned_lib")

def _dependents(suffix, adopted):
    """The old-rule dependents of the adopted label `adopted`, named with `suffix`: a library whose welded test calls the codec, a `mojo_test` and a shared library
    whose driver calls into it. The library has a kcov and a branch coverage build whatever the switch says (`coverage_debug`)."""
    mojo_library(
        name = "consumer" + suffix,
        srcs = ["syslib_consumer/__init__.mojo"],
        test_srcs = ["tests/test_consumer.mojo"],
        deps = [adopted],
        import_name = "syslib_consumer",
        conda = False,
        readme = False,
        coverage_debug = "komira//tools/build/coverage/kcov:cov_link",
    )

    # `buck2 test` runs it through the gate.
    mojo_test(
        name = "program_test" + suffix,
        main = "tests/test_program.mojo",
        srcs = ["tests/test_program.mojo"],
        deps = [adopted],
    )

def adopt_system_libs_case():
    # Every package declares its doc_tree (tests//:doc_tree collects it), with or without a case.
    package_docs()

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

    # What the gated `:lib` of a package that pins the two libraries is: the library's file and the directories.
    pinned_lib(name = "codec_lib", lib = ":codec", system_libs = [":libsqlite", ":libzlib"])
    mojo_adopted_library(
        name = "adopted",
        import_name = "syslib_codec",
        lib = ":codec_lib",
        srcs = ["syslib_codec/__init__.mojo"],
        test_runs = ":codec[tests]",
        test_srcs = ["tests/test_codec.mojo"],
    )
    _dependents("", ":adopted")

    # A shared library over the adopted label: its driver loads it, and its export opens SQLite.
    mojo_shared_lib(
        name = "probe",
        srcs = ["shared_probe.mojo"],
        exports = ["probe_sqlite"],
        out_name = "syslib_probe",
        gate_srcs = ["shared_driver.mojo"],
        deps = [":adopted"],
    )

    # The defect: the same package whose `:lib` forgot its pins, `-c adopt_system_libs.case=unpinned`.
    if read_config("adopt_system_libs", "case", "") == "unpinned":
        pinned_lib(name = "codec_lib_unpinned", lib = ":codec")
        mojo_adopted_library(
            name = "adopted_unpinned",
            import_name = "syslib_codec",
            lib = ":codec_lib_unpinned",
            srcs = ["syslib_codec/__init__.mojo"],
            test_runs = ":codec[tests]",
            test_srcs = ["tests/test_codec.mojo"],
        )
        _dependents("_unpinned", ":adopted_unpinned")
        mojo_shared_lib(
            name = "probe_unpinned",
            srcs = ["shared_probe.mojo"],
            exports = ["probe_sqlite"],
            out_name = "syslib_probe",
            gate_srcs = ["shared_driver.mojo"],
            deps = [":adopted_unpinned"],
        )
