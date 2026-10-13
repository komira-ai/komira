# =============================================================================
# src/kci_validate/tests/test_readme_link_release.mojo
#   The link commands of an installed README over a WRITTEN release
#   (kci_publish's ExampleRelease), where test_readme_link.mojo hands the
#   closure in as LinkNodes:
#
#   * `link_nodes` reads every library member's `depends` (first words) and
#     `lib_files` (a `link` row lib/lib<X>.so is shared library X, a `static`
#     row lib/lib<Y>.a is archive Y, a `shared` row is not read), and skips
#     the metapackage; `install_pins` puts the closure's arguments in each
#     library pin's `link` (dependents first: komira_gamma, which has no
#     native file, needs komira_beta's before komira_alpha's, which name
#     order would reverse) and leaves the metapackage's empty; a `link` row
#     of another shape raises. Mutants it catches: `pin.link = LinkArgs()` in
#     request.mojo, a `shared` row read as a link name, the metapackage read
#     as a library. Each library pin's `codecs` are the `dlopen` sonames of
#     its whole closure (`closure_codecs`).
#   * the CONDA_INSTALL_ENV run of a library shipping a shared library: the
#     played `mojo run` argv carries the installed README's block's `run`
#     arguments, `$CONDA_PREFIX` replaced by the environment, before the
#     program. Mutant it catches: `run_program_argv(work, p.file)` at the call
#     site (native_rows.mojo `run_readme`, which conda_install_env.mojo's
#     step 4 calls; the link arguments dropped).
#
# Hermetic: TEST_TMPDIR, kci_build's ScriptedRunner as pixi, kci_pkg_upload's
# ScriptedPkgTransport as the network. The README examples tool is this
# test's data (`readme_examples`).
# =============================================================================

from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import VALIDATION_KIND_CONDA_INSTALL_ENV
from kci_build import ScriptedRunner, ScriptedStep
from kci_pkg_upload import PkgResponse, ScriptedPkgTransport, content_identity_of
from kci_publish import NoWaitSleeper
from kci_publish.release_fixture import ExampleRelease, FixtureMember, example_loaded, write_example_inputs, write_text_file
from kci_release_machine import StageValidation
from komira_runtime_paths import data_path
from kci_validate import (
    EnvHost,
    RecordingIndexPollLog,
    ValidateRequest,
    install_env_argv,
    install_pins,
    link_nodes,
    run_install_env,
    run_program_argv,
)

comptime SHA_A: String = "1111111111111111111111111111111111111111111111111111111111111111"
comptime SHA_B: String = "2222222222222222222222222222222222222222222222222222222222222222"
comptime SHA_C: String = "3333333333333333333333333333333333333333333333333333333333333333"


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/readme_link_release/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _sha(text: String) -> String:
    return content_identity_of(text.as_bytes()).sha256_hex


def _row(kind: String, path: String, sha: String) -> String:
    return String('{"kind":"') + kind + String('","path":"') + path + String('","sha256":"') + sha + String('"}')


def _joined(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        if i > 0:
            s += String(" ")
        s += xs[i]
    return s^


# ---- link_nodes and install_pins over a written release ---------------------


def _three_libraries(alpha_link_path: String = String("lib/libkomira_alpha_native.so")) -> ExampleRelease:
    """komira_alpha ships a shared library (link and shared rows) and a static
    archive; komira_beta requires alpha and ships a shared library;
    komira_gamma requires beta and ships nothing; komira is the metapackage."""
    var r = ExampleRelease()
    var gamma = FixtureMember(String("komira_gamma"), String("library"), String("gamma conda bytes"))
    gamma.internal.append(String("komira_beta"))
    r.members.insert(2, gamma^)
    r.set_meta(
        String("komira_alpha"), String("lib_files"),
        String("[") + _row(String("static"), String("lib/libkomira_alpha_holder.a"), String(SHA_C)) + String(",")
        + _row(String("link"), alpha_link_path, String(SHA_A)) + String(",")
        + _row(String("shared"), String("lib/libkomira_alpha_native.so.1"), String(SHA_A)) + String("]"),
    )
    r.set_meta(
        String("komira_beta"), String("lib_files"),
        String("[") + _row(String("link"), String("lib/libkomira_beta_native.so"), String(SHA_B)) + String(",")
        + _row(String("shared"), String("lib/libkomira_beta_native.so.1"), String(SHA_B)) + String("]"),
    )
    return r^


def _names(*xs: String) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(xs[i].copy())
    return out^


def test_link_nodes_read_depends_and_lib_files_of_every_library_member() raises:
    var r = _three_libraries()
    var dir = _tmp(String("nodes"))
    r.write(dir)
    var nodes = link_nodes(example_loaded(r, dir))
    # the metapackage is no node
    assert_equal(len(nodes), 3)
    var seen = 0
    for i in range(len(nodes)):
        ref n = nodes[i]
        if n.name == String("komira_alpha"):
            seen += 1
            # the link row only: the shared row (lib/lib...so.1) is the same library
            assert_equal(_joined(n.shared), String("komira_alpha_native"))
            assert_equal(_joined(n.statics), String("komira_alpha_holder"))
        elif n.name == String("komira_beta"):
            seen += 1
            assert_equal(_joined(n.shared), String("komira_beta_native"))
            assert_equal(len(n.statics), 0)
            # first words: the pin `komira_alpha ==1.0.0 h..._3` is komira_alpha
            assert_equal(_joined(n.depends), String("__linux mojo-compiler komira_alpha"))
        elif n.name == String("komira_gamma"):
            seen += 1
            assert_equal(len(n.shared), 0)
            assert_equal(len(n.statics), 0)
            assert_equal(_joined(n.depends), String("__linux mojo-compiler komira_beta"))
    assert_equal(seen, 3)


comptime ALPHA_RUN: String = "-Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_alpha_native"
comptime TAIL: String = " -Xlinker -lkomira_alpha_holder -Xlinker -rpath -Xlinker $ORIGIN/../lib"


def test_install_pins_carry_each_librarys_closure_link_arguments() raises:
    var r = _three_libraries()
    var dir = _tmp(String("pins"))
    r.write(dir)
    var pins = install_pins(example_loaded(r, dir), _names(String("komira_gamma"), String("komira_alpha"), String("komira")))
    assert_equal(len(pins), 3)
    # gamma ships nothing, but its closure does: beta (which reaches two
    # shared libraries) before alpha (one), the reverse of name order
    assert_equal(
        _joined(pins[0].link.run),
        String("-Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_beta_native -Xlinker -lkomira_alpha_native"),
    )
    assert_equal(
        _joined(pins[0].link.build),
        String("-Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_beta_native -Xlinker -lkomira_alpha_native") + String(TAIL),
    )
    # alpha's own closure is alpha alone
    assert_equal(_joined(pins[1].link.run), String(ALPHA_RUN))
    assert_equal(_joined(pins[1].link.build), String(ALPHA_RUN) + String(TAIL))
    # the metapackage has no link arguments
    assert_false(pins[2].is_library)
    assert_true(pins[2].link.is_empty())


def test_install_pins_carry_the_codecs_each_closure_opens() raises:
    # alpha opens liblz4.so.1 and beta libzstd.so.1 (metadata.json dlopen
    # rows): gamma's closure opens both, through its dependencies; alpha's
    # only its own; the metapackage none. A codec no closure declares is
    # the toolchain's, which the `loaded_from` row does not judge (kci run
    # 38348429425). Mutant: `pin.codecs` left empty in install_pins.
    var r = _three_libraries()
    r.set_meta(String("komira_alpha"), String("dlopen"), String('[{"requirement":"lz4-c >=1.9.3,<2","soname":"liblz4.so.1"}]'))
    r.set_meta(String("komira_beta"), String("dlopen"), String('[{"requirement":"zstd >=1.5.2,<2","soname":"libzstd.so.1"}]'))
    var dir = _tmp(String("codecs"))
    r.write(dir)
    var pins = install_pins(example_loaded(r, dir), _names(String("komira_gamma"), String("komira_alpha"), String("komira")))
    assert_equal(_joined(pins[0].codecs), String("libzstd.so.1 liblz4.so.1"))
    assert_equal(_joined(pins[1].codecs), String("liblz4.so.1"))
    assert_equal(len(pins[2].codecs), 0)


def test_a_link_row_of_another_shape_is_refused_by_install_pins() raises:
    var r = _three_libraries(String("lib/libkomira_alpha_native"))
    var dir = _tmp(String("bad_row"))
    r.write(dir)
    var why = String("")
    try:
        _ = install_pins(example_loaded(r, dir), _names(String("komira_alpha")))
    except e:
        why = String(e)
    assert_equal(why, String("lib_files path 'lib/libkomira_alpha_native' is not lib/lib<name>.so"))


# ---- the README run is given the block's arguments ----------------------------

comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime COMPILER: String = "https://conda.example.invalid/max"
comptime META: String = ".pixi/envs/default/conda-meta/"
comptime DOC: String = ".pixi/envs/default/share/doc/komira_alpha/README.md"
comptime PROGRAM: String = "readme_komira_alpha.mojo"
comptime PIXI_BYTES: String = "#!/bin/false\nthe pinned pixi, played\n"
comptime README: String = (
    "# komira_alpha\n"
    "\n"
    "```mojo\n"
    "from std.testing import assert_equal\n"
    "from komira_alpha import alpha\n"
    "\n"
    "assert_equal(alpha(1), 2)\n"
    "```\n"
    "\n"
    "## Linking\n"
    "\n"
    "```sh komira-link\n"
    "mojo run -Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_alpha_native prog.mojo\n"
    "mojo build -Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_alpha_native"
    " -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o $CONDA_PREFIX/bin/prog\n"
    "```\n"
)


def _resp(status: Int, body: String = String("")) -> PkgResponse:
    var r = PkgResponse(status)
    var b = List[UInt8]()
    var s = body.as_bytes()
    for i in range(len(s)):
        b.append(s[i])
    r.with_body(b^)
    return r^


def _record(r: ExampleRelease, name: String) -> String:
    var b = r.build()
    return (
        String('{"name":"') + name + String('","version":"') + r.version + String('","build":"') + b
        + String('","sha256":"') + r.sha256_of(name) + String('","url":"') + String(CHANNEL) + String("/linux-64/")
        + name + String("-") + r.version + String("-") + b + String('.conda"}')
    )


def test_the_readme_run_is_given_the_blocks_run_arguments() raises:
    var root = _tmp(String("run"))
    var r = ExampleRelease()
    r.set_meta(
        String("komira_alpha"), String("doc_files"),
        String('[{"path":"share/doc/komira_alpha/README.md","sha256":"') + _sha(String(README)) + String('"}]'),
    )
    r.set_meta(
        String("komira_alpha"), String("lib_files"),
        String("[") + _row(String("link"), String("lib/libkomira_alpha_native.so"), String(SHA_A)) + String(",")
        + _row(String("shared"), String("lib/libkomira_alpha_native.so.1"), String(SHA_A)) + String("]"),
    )
    var p = write_example_inputs(r, root, String("gamma"))
    makedirs(root + String("/repo"), exist_ok=True)
    makedirs(root + String("/tools"), exist_ok=True)
    write_text_file(root + String("/tools/pixi"), String(PIXI_BYTES))
    var v = StageValidation(7)
    v.name = String("install-env")
    v.kind = String(VALIDATION_KIND_CONDA_INSTALL_ENV)
    v.installs.append(String("komira_alpha"))
    v.compiler_channel = String(COMPILER)
    v.extra_channels.append(String("conda-forge"))
    v.wait_for_index_seconds = 0
    var req = ValidateRequest(v^)
    req.stage = String("gamma")
    req.step_name = String("publish")
    req.artifacts_file = p.artifacts_file.copy()
    req.channels_file = p.channels_file.copy()
    req.channel = String("gamma")
    req.release_dir = p.release_dir.copy()
    req.platform = p.platform.copy()
    req.revision_id = p.revision_id.copy()
    req.scratch_dir = root + String("/scratch")
    req.repo_root = root + String("/repo")
    req.pixi = root + String("/tools/pixi")
    req.pixi_sha256 = _sha(String(PIXI_BYTES))
    req.readme_tool = data_path(String("readme_examples"))
    var work = req.scratch_dir + String("/install-env/work")
    var env = work + String("/.pixi/envs/default")

    # pixi install leaves the records, the README and the payload
    var runner = ScriptedRunner()
    var install = ScriptedStep(install_env_argv(work), exit_code=Int32(0), stderr_text=String("installed\n"))
    for name in [String("komira_alpha"), String("komira_beta"), String("komira")]:
        install.writes(String(META) + name + String(".json"), _record(r, name))
    install.writes(
        String(META) + String("mojo-compiler.json"),
        String('{"name":"mojo-compiler","version":"1.0.0","build":"release","sha256":"')
        + String("4444444444444444444444444444444444444444444444444444444444444444")
        + String('","url":"') + String(COMPILER) + String('/linux-64/mojo-compiler-1.0.0-release.conda"}'),
    )
    install.writes(String(DOC), String(README))
    install.writes(String(".pixi/envs/default/lib/mojo/komira_alpha.mojoc"), String("komira_alpha"))
    runner.expect(install^)
    # the README run: the block's run words, the environment for
    # $CONDA_PREFIX, written out here, between `run` and the program
    var want = run_program_argv(work, String(PROGRAM))
    var program = want.pop()
    for w in [String("-Xlinker"), String("-L") + env + String("/lib"), String("-Xlinker"), String("-lkomira_alpha_native")]:
        want.append(w.copy())
    want.append(program.copy())
    runner.expect(
        ScriptedStep(want.copy(), exit_code=Int32(0), stdout_text=String("readme_komira_alpha validation: 1 of 1 checks passed\n"))
    )

    var t = ScriptedPkgTransport()
    t.queue(_resp(200))
    t.queue(_resp(404))
    var index = String('{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{')
    var first = True
    for name in [String("komira_alpha"), String("komira_beta"), String("komira")]:
        if not first:
            index += String(",")
        first = False
        index += String('"') + r.file_name(name) + String('":{"sha256":"') + r.sha256_of(name) + String('","size":1}')
    t.queue(_resp(200, index + String("}}")))
    t.queue(_resp(200, String("alpha conda bytes")))
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var row = run_install_env(runner, t, sl, log, req, EnvHost(root + String("/etc_pixi")))

    # both scripted children ran, the README run with exactly the argv
    # above (the native rows that follow are test_native_rows.mojo's; this
    # script plays none of them)
    assert_equal(runner.remaining(), 0)
    assert_true(len(runner.calls) >= 2)
    assert_equal(_joined(runner.calls[1].argv), _joined(want))
    assert_equal(runner.calls[1].argv[len(runner.calls[1].argv) - 1], program)
    # the readme and program rows passed (the played environment installs
    # no .so, so the native rows are not what this proves)
    var readme_ok = False
    var program_ok = False
    for i in range(len(row.checks)):
        ref c = row.checks[i]
        if c.check == String("readme"):
            assert_true(c.ok, c.got)
            readme_ok = True
        if c.check == String("program"):
            assert_true(c.ok, c.got)
            program_ok = True
    assert_true(readme_ok)
    assert_true(program_ok)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
