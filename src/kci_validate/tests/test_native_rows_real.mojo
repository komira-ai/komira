# =============================================================================
# src/kci_validate/tests/test_native_rows_real.mojo
#   The native install rows on real packages: the three refusals of correct
#   installs in kci run 38348429425 (the first beta_validate to run slice
#   11's rows on released packages), each reproduced here, and the codec
#   defects the rows exist for, which must stay red.
#
#   (1) the loader's path: the Mojo compiler finds the environment's
#       libraries through its DT_RPATH `$ORIGIN/../lib`, so the loader names
#       liblz4.so.1 `<env>/bin/../lib/liblz4.so.1`; with both sides resolved
#       (realpath, or lexically for a path that does not exist) that is
#       <env>/lib and passes, in `loaded_from_findings` and alone. A path
#       that only spells <env>/lib (`<env>/lib/../../x/`) and a lib/ entry
#       that is a symbolic link out of the environment are refused.
#       Mutant: `resolved_path` returning its argument;
#   (2) the toolchain's libraries: the Mojo compiler loads libzstd.so.1 and
#       libz.so.1 from /lib itself; a library whose closure declares neither
#       (kci_api) has a green row, and a package declaring liblz4.so.1 alone
#       is judged on liblz4.so.1 only. A declared codec from /lib and a
#       komira object from /usr/lib stay red whatever is declared. Mutant:
#       `loaded_from_findings` judging every codec of kci_release_set's
#       `system_libs()` instead of `codecs`;
#   (3) the static holder, alone: a README whose block's build line links a
#       static archive its run line does not (komira_log's holder) runs as
#       `mojo build` into the alone environment's bin/, then the built
#       program, under the loader's record (step 4's case:
#       test_native_rows.mojo `test_a_static_holder_readme_is_built_and_its_program_run`).
#       Mutant: `runs_built` returning False;
#   (codec) slice 4's planted defect, as a member of a set installed alone
#       (`_alone_rows`): komira_lz4 whose README loads liblz4.so.1 from
#       /usr/lib is red with its requirement missing and with it declared.
#       Mutants: `is_native` deciding from the requirement (the
#       missing-requirement case has no row), and `_alone_rows` returning
#       for a pin with no `lib_files`.
#
# Hermetic: TEST_TMPDIR, kci_build's ScriptedRunner; no pixi, no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs, symlink
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import VALIDATION_KIND_CONDA_INSTALL_ENV, ResultValidationCheck
from kci_build import ScriptedRunner, ScriptedStep
from kci_publish.release_fixture import write_text_file
from kci_release_machine import StageValidation
from kci_validate import (
    InstallPin,
    LinkArgs,
    ReadmeProgram,
    build_link_args,
    build_program_argv,
    install_env_argv,
    lexical_path,
    links_static,
    loaded_from_findings,
    run_native_rows,
    run_program_argv,
)

comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime COMPILER: String = "https://conda.example.invalid/max"
comptime ENV: String = ".pixi/envs/default"
comptime COUNT: String = "readme_komira_lz4 validation: 1 of 1 checks passed\n"
comptime LZ4_TRACE: String = (
    "     103:\tcalling init: /lib/x86_64-linux-gnu/libc.so.6\n"
    "     103:\tcalling init: /usr/lib/x86_64-linux-gnu/liblz4.so.1\n"
)
# what the Mojo compiler loads for itself, outside any package's closure
comptime TOOLCHAIN_TRACE: String = (
    "     104:\tcalling init: /lib/x86_64-linux-gnu/libzstd.so.1\n"
    "     104:\tcalling init: /lib/x86_64-linux-gnu/libz.so.1\n"
)


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/native_rows_real_") + String(Int(external_call["getpid", Int32]())) + String("/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _joined(xs: List[String]) -> String:
    return String(" | ").join(xs)


def _lz4() -> List[String]:
    var c: List[String] = [String("liblz4.so.1")]
    return c^


def _init(path: String) -> String:
    return String("     41:\tcalling init: ") + path + String("\n")


# ---- (1) the loader's path, resolved ------------------------------------------------


def test_lexical_path() raises:
    assert_equal(lexical_path(String("/e/bin/../lib/liblz4.so.1")), String("/e/lib/liblz4.so.1"))
    assert_equal(lexical_path(String("/e/lib/../../x/liblz4.so.1")), String("/x/liblz4.so.1"))
    assert_equal(lexical_path(String("/e//lib/./a")), String("/e/lib/a"))
    assert_equal(lexical_path(String("/../a")), String("/a"))
    assert_equal(lexical_path(String("/")), String("/"))


def test_a_codec_found_through_bin_dotdot_lib_is_in_the_environment() raises:
    # kci run 38348429425: "liblz4.so.1 was loaded from <env>/bin/../lib/
    # liblz4.so.1, not from <env>/lib/" (komira_lz4; libz.so.1 for komira_zlib)
    var env = _tmp(String("dotdot"))
    makedirs(env + String("/bin"), exist_ok=True)
    makedirs(env + String("/lib"), exist_ok=True)
    write_text_file(env + String("/lib/liblz4.so.1.10.0"), String("lz4, played"))
    symlink(String("liblz4.so.1.10.0"), env + String("/lib/liblz4.so.1"))
    var trace = _init(env + String("/bin/../lib/liblz4.so.1")) + _init(env + String("/bin/../lib/libkomira_alpha_native.so.1"))
    var f = loaded_from_findings(trace, env, _lz4())
    assert_equal(len(f), 0, _joined(f))


def test_a_path_that_only_spells_the_environment_lib_is_refused() raises:
    var env = _tmp(String("spells"))
    makedirs(env + String("/lib"), exist_ok=True)
    var outside = env + String("/lib/../../elsewhere/liblz4.so.1")
    var f = loaded_from_findings(_init(outside), env, _lz4())
    assert_equal(len(f), 1, _joined(f))
    assert_equal(f[0], String("liblz4.so.1 was loaded from ") + outside + String(", not from ") + env + String("/lib/"))


def test_a_lib_entry_linking_out_of_the_environment_is_refused() raises:
    var env = _tmp(String("linked_out"))
    var other = _tmp(String("linked_out_other"))
    makedirs(env + String("/lib"), exist_ok=True)
    write_text_file(other + String("/libkomira_alpha_native.so.1"), String("not this environment's"))
    symlink(other + String("/libkomira_alpha_native.so.1"), env + String("/lib/libkomira_alpha_native.so.1"))
    var f = loaded_from_findings(_init(env + String("/lib/libkomira_alpha_native.so.1")), env, List[String]())
    assert_equal(len(f), 1, _joined(f))
    assert_true(f[0].startswith(String("libkomira_alpha_native.so.1 was loaded from ") + env + String("/lib/")), f[0])


# ---- (2) only what the closure declares ---------------------------------------------


def test_the_toolchains_own_libraries_are_not_judged() raises:
    # kci run 38348429425: "readme_kci_api: libzstd.so.1 was loaded from
    # /lib/x86_64-linux-gnu/libzstd.so.1 ...; libz.so.1 was loaded from
    # /lib/x86_64-linux-gnu/libz.so.1": kci_api's closure opens no codec
    var env = _tmp(String("toolchain"))
    makedirs(env + String("/lib"), exist_ok=True)
    var trace = String(TOOLCHAIN_TRACE) + _init(env + String("/lib/libkomira_alpha_native.so.1"))
    var f = loaded_from_findings(trace, env, List[String]())
    assert_equal(len(f), 0, _joined(f))
    # a package declaring liblz4.so.1 is judged on it, not on the others
    var f2 = loaded_from_findings(String(TOOLCHAIN_TRACE) + _init(env + String("/lib/liblz4.so.1")), env, _lz4())
    assert_equal(len(f2), 0, _joined(f2))


def test_a_declared_codec_or_a_komira_object_from_outside_stays_red() raises:
    var env = _tmp(String("declared"))
    makedirs(env + String("/lib"), exist_ok=True)
    var zstd: List[String] = [String("libzstd.so.1")]
    var f = loaded_from_findings(String(TOOLCHAIN_TRACE), env, zstd)
    assert_equal(len(f), 1, _joined(f))
    assert_equal(
        f[0], String("libzstd.so.1 was loaded from /lib/x86_64-linux-gnu/libzstd.so.1, not from ") + env + String("/lib/")
    )
    var f2 = loaded_from_findings(_init(String("/usr/lib/libkomira_alpha_native.so.1")), env, List[String]())
    assert_equal(len(f2), 1, _joined(f2))
    assert_true(f2[0].startswith(String("libkomira_alpha_native.so.1 was loaded from /usr/lib/")), f2[0])


# ---- a member of a set, installed alone ------------------------------------------------


struct Alone(Movable):
    """`run_native_rows` for a set whose member komira_lz4 ships no native
    file and has dlopen rows, its README run alone; the runner scripted by
    the test between `__init__` and `run`."""

    var dir: String
    var awork: String
    var named: List[InstallPin]
    var pins: List[InstallPin]
    var programs: List[ReadmeProgram]
    var runner: ScriptedRunner

    def __init__(out self, sub: String, var depends: List[String]) raises:
        var root = _tmp(sub)
        var lz4 = InstallPin(String("komira_lz4"))
        lz4.version = String("1.0.0")
        lz4.build = String("h0_1")
        lz4.subdir = String("linux-64")
        lz4.is_library = True
        lz4.import_name = String("komira_lz4")
        lz4.has_dlopen = True
        lz4.depends = depends^
        var meta = InstallPin(String("komira"))
        meta.version = String("1.0.0")
        meta.build = String("h0_1")
        meta.subdir = String("linux-64")
        self.named = List[InstallPin]()
        self.named.append(meta.copy())
        self.pins = List[InstallPin]()
        self.pins.append(meta.copy())
        self.pins.append(lz4^)
        self.dir = root + String("/install-set")
        makedirs(self.dir + String("/work/out"), exist_ok=True)
        var program = ReadmeProgram()
        program.file = String("readme_komira_lz4.mojo")
        program.text = String("the README runner, played\n")
        program.package = String("komira_lz4")
        program.display = String("src/komira_lz4/README.md")
        # its closure's dlopen rows, which install_pins reads from metadata.json
        program.codecs = _lz4()
        self.programs = List[ReadmeProgram]()
        self.programs.append(program^)
        self.awork = self.dir + String("/alone/komira_lz4/work")
        self.runner = ScriptedRunner()
        var install = ScriptedStep(install_env_argv(self.awork))
        install.writes(String(ENV) + String("/conda-meta/komira_lz4-1.0.0-h0_1.json"), String('{"name":"komira_lz4"}'))
        install.writes(String(ENV) + String("/bin/mojo"), String("the compiler, played"))
        install.writes(String(ENV) + String("/lib/liblz4.so.1"), String("lz4, played"))
        self.runner.expect(install^)

    def aenv(self) -> String:
        return self.awork + String("/") + String(ENV)

    def mojo_run(mut self, trace: String):
        var readme = ScriptedStep(run_program_argv(self.awork, String("readme_komira_lz4.mojo"), List[String]()), stdout_text=String(COUNT))
        readme.writes(String("out/readme_komira_lz4.ld.103"), trace.copy())
        self.runner.expect(readme^)

    def run(mut self) raises -> List[ResultValidationCheck]:
        var v = StageValidation(7)
        v.name = String("install-set")
        v.kind = String(VALIDATION_KIND_CONDA_INSTALL_ENV)
        v.installs.append(String("komira"))
        v.compiler_channel = String(COMPILER)
        var checks = List[ResultValidationCheck]()
        run_native_rows(self.runner, v, String(CHANNEL), String("1.0.0"), self.dir, self.named, self.pins, self.programs, checks)
        var order = String("")
        for i in range(len(checks)):
            if i > 0:
                order += String(" ")
            order += checks[i].check
        # no lib_files: no per-library rows, no build, no load; only alone
        assert_equal(order, String("alone loaded_from"))
        assert_true(checks[0].ok, checks[0].got)
        return checks^

    def done(self) raises:
        """Every scripted run happened (checked after the rows, so a red row
        says why first)."""
        assert_equal(self.runner.remaining(), 0)


def _depends(lz4c: Bool) -> List[String]:
    var d: List[String] = [String("__linux")]
    if lz4c:
        d.append(String("lz4-c >=1.9.3,<2"))
    return d^


def _red_alone(sub: String, lz4c: Bool) raises:
    var a = Alone(sub, _depends(lz4c))
    a.mojo_run(String(LZ4_TRACE))
    var checks = a.run()
    assert_false(checks[1].ok)
    assert_equal(
        checks[1].got,
        String("loaded_from: komira_lz4 alone: liblz4.so.1 was loaded from /usr/lib/x86_64-linux-gnu/liblz4.so.1, not from ")
        + a.aenv() + String("/lib/"),
    )
    a.done()


def test_a_codec_package_missing_its_requirement_is_red_alone() raises:
    # slice 4's planted defect: komira_lz4 without lz4-c, installed alone
    _red_alone(String("codec-missing"), False)


def test_a_codec_only_package_loading_the_system_codec_is_red_alone() raises:
    # the requirement declared, the codec still loaded from /usr/lib
    _red_alone(String("codec-declared"), True)


def test_alone_the_codec_through_bin_dotdot_lib_and_the_toolchains_loads_pass() raises:
    # (1) and (2) together, as komira_lz4 alone met them in kci run 38348429425
    var a = Alone(String("alone-real"), _depends(True))
    a.mojo_run(
        String(TOOLCHAIN_TRACE) + _init(a.aenv() + String("/bin/../lib/liblz4.so.1"))
    )
    var checks = a.run()
    assert_true(checks[1].ok, checks[1].got)
    a.done()


def test_alone_a_static_holder_readme_is_built_then_run() raises:
    # (3): "JIT session error: Symbols not found: [ komira_log_config_holder_set,
    # ... ]" for readme_komira_log and readme_kci_reconciler, alone too
    var a = Alone(String("alone-holder"), _depends(True))
    var block = LinkArgs()
    block.run = [String("-Xlinker"), String("-L$CONDA_PREFIX/lib")]
    block.build = block.run.copy()
    for w in [String("-Xlinker"), String("-lkomira_log_holder"), String("-Xlinker"), String("-rpath"), String("-Xlinker"), String("$ORIGIN/../lib")]:
        block.build.append(w.copy())
    a.programs[0].block = block.copy()
    var exe = a.aenv() + String("/bin/readme_komira_lz4")
    a.runner.expect(
        ScriptedStep(build_program_argv(a.awork, String("readme_komira_lz4.mojo"), build_link_args(block, a.aenv()), exe))
    )
    var built = ScriptedStep(List[String](), stdout_text=String(COUNT))
    built.writes(String("out/readme_komira_lz4.ld.105"), _init(a.aenv() + String("/lib/liblz4.so.1")))
    a.runner.expect(built^)
    var checks = a.run()
    assert_true(checks[1].ok, checks[1].got)
    a.done()
    assert_true(links_static(block))
    assert_true(a.programs[0].runs_built())
    assert_equal(a.runner.calls[2].path, exe)
    var env = a.runner.calls[2].env.value().copy()
    var traced = False
    for i in range(len(env)):
        if env[i] == String("LD_DEBUG=libs"):
            traced = True
    assert_true(traced)


def test_links_static() raises:
    # the block of a closure with shared libraries only links nothing static
    var shared = LinkArgs()
    shared.run = [String("-Xlinker"), String("-L$CONDA_PREFIX/lib"), String("-Xlinker"), String("-lkomira_x")]
    shared.build = shared.run.copy()
    for w in [String("-Xlinker"), String("-rpath"), String("-Xlinker"), String("$ORIGIN/../lib")]:
        shared.build.append(w.copy())
    assert_false(links_static(shared))
    assert_false(links_static(LinkArgs()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
