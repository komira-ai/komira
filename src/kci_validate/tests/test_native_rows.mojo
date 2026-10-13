# =============================================================================
# src/kci_validate/tests/test_native_rows.mojo
#   docs/design/native_packaging.md's install checks 2 to 7 as a
#   CONDA_INSTALL_ENV validation (what beta's `beta_validate` runs) runs them
#   (native_rows.mojo), over a played pixi:
#
#   (0) the pass: komira_alpha ships a shared library (its `.so`, a minimal
#       ELF this test writes, and the link to it) and requires
#       `__glibc >=2.34`; installed alone, the validation adds after its
#       README program, in order: `loaded_from` (the README run under
#       LD_DEBUG=libs, its record read), `lib_files glibc needed symbolic`,
#       `built` (mojo build with the block's build words, the built program
#       run) and its `loaded_from`, `load` (the generated program over
#       every shared row, RTLD_NOW) and `openssl` (a third environment with
#       conda-forge's openssl, one program per shared library), all ok. The
#       README run's environment carries LD_DEBUG and LD_DEBUG_OUTPUT and no
#       LD_LIBRARY_PATH; the load program is `load_program_text` of the
#       installed .so; the openssl environment's manifest requires
#       `openssl 3.*` from conda-forge; the whole set's and the openssl
#       environment's manifests declare `[system-requirements] libc` at
#       kci_release_set's glibc floor for linux-64 (without it pixi assumes
#       glibc 2.28 and no `__glibc >=2.34` package resolves). Mutant: the
#       `[system-requirements]` block dropped from `install_manifest_text`;
#   (b) row 4 red: a planted .so with an unresolved symbol, which the load
#       program reports as `FAILED <path>: ... undefined symbol: ...`: the
#       `load` row fails naming the .so and the symbol, and only it.
#       Mutant: the `_load_row` call in `run_native_rows` removed (the pass
#       then lacks `load` in its order, and this test has no failed row);
#   (5) a README run whose loader record names the komira .so from
#       /usr/lib: `loaded_from` fails;
#   (7) the openssl program failing: `openssl` fails naming the owner;
#   (set) `run_native_rows` for a set (the metapackage named, komira_alpha a
#       member): komira_alpha is installed alone (its own manifest, the
#       whole set's pixi cache), its .so loaded there and its README run
#       under the loader's record; a validation without conda-forge gets a
#       failed `openssl` row naming it and runs no openssl install;
#   (alone) `alone_pins`: a metapackage's native members each get an
#       environment of their own (a `lib_files` library, and a library with
#       metadata.json `dlopen` rows, with its codec's requirement or
#       without), a plain library does not; a validation installing one
#       native package by itself needs none;
#   (codec) a library shipping no native file whose `dlopen` rows name
#       liblz4.so.1 and whose depends lack lz4-c (slice 4's planted defect)
#       is native: installed by itself, its README runs under the loader's
#       record and the codec loaded from /usr/lib makes `loaded_from` red;
#       as a member of a set, installed alone (`_alone_rows`), the same
#       record makes its alone `loaded_from` red, with the requirement
#       missing and with it declared. Mutants: `is_native` deciding from
#       the requirement (the missing-requirement cases have no row), and
#       `_alone_rows` returning for a pin with no `lib_files`;
#   (load) `load_findings`: every path LOADED passes; a path not reported
#       and a run that failed with no line are findings.
#   (gen) the two generated programs equal tests/generated/'s copies, which the
#       package's BUCK compiles; the extra environments share the whole
#       set's pixi cache.
#   A release with no native pin gets none of these rows and no extra run:
#   test_conda_install_env.mojo's pass asserts its rows and its two runs.
#
# Hermetic: TEST_TMPDIR, kci_publish's ExampleRelease, kci_build's
# ScriptedRunner (wrapped to leave the .so and its link, which a script's
# text files cannot be), kci_pkg_upload's ScriptedPkgTransport; no pixi, no
# network. The README examples tool is this test's data.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs, symlink
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import OUTCOME_SUCCEEDED, OUTCOME_VALIDATION_FAILED, VALIDATION_KIND_CONDA_INSTALL_ENV, ResultValidation, ResultValidationCheck
from kci_build import ProcessRunner, RunResult, RunSpec, ScriptedRunner, ScriptedStep
from kci_pkg_upload import PkgResponse, ScriptedPkgTransport, content_identity_of
from kci_publish import NoWaitSleeper
from kci_publish.release_fixture import ExampleRelease, write_example_inputs, write_text_file
from kci_release_machine import StageValidation
from kci_release_set.conda_metadata import LibFile
from kci_release_set.glibc_floor import glibc_floor_of
from kci_release_set.member import file_sha256_hex
from komira_runtime_paths import data_path
from kci_validate import (
    EnvHost,
    InstallPin,
    ReadmeProgram,
    RecordingIndexPollLog,
    ValidateRequest,
    alone_pins,
    build_program_argv,
    install_env_argv,
    load_findings,
    load_program_text,
    openssl_program_text,
    run_install_env,
    run_native_rows,
    run_program_argv,
)

comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime COMPILER: String = "https://conda.example.invalid/max"
comptime ENV: String = ".pixi/envs/default"
comptime SO: String = "lib/libkomira_alpha_native.so.1"
comptime LINK: String = "lib/libkomira_alpha_native.so"
comptime PROGRAM: String = "readme_komira_alpha.mojo"
comptime COUNT: String = "readme_komira_alpha validation: 1 of 1 checks passed\n"
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
# komira_alpha as a package that ships no native file and opens a system
# codec (komira_lz4's shape): its README has no link block
comptime README_CODEC: String = (
    "# komira_alpha\n"
    "\n"
    "```mojo\n"
    "from std.testing import assert_equal\n"
    "from komira_alpha import alpha\n"
    "\n"
    "assert_equal(alpha(1), 2)\n"
    "```\n"
)
comptime LZ4_ROW: String = '[{"requirement":"lz4-c >=1.9.3,<2","soname":"liblz4.so.1"}]'


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/native_rows_") + String(Int(external_call["getpid", Int32]())) + String("/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _sha(text: String) -> String:
    return content_identity_of(text.as_bytes()).sha256_hex


def _chmod(path: String, mode: Int32) raises:
    var p = path
    # SAFETY: `p` pins the NUL-terminated path across the synchronous call.
    var rc = external_call["chmod", Int32](p.as_c_string_slice().unsafe_ptr(), mode)
    if rc != 0:
        raise Error("test: chmod failed for '" + path + "'")


def _put(mut b: List[UInt8], off: Int, v: Int, n: Int):
    for i in range(n):
        b[off + i] = UInt8((v >> (8 * i)) & 0xFF)


def _str_at(mut t: List[UInt8], s: String) -> Int:
    var at = len(t)
    var b = s.as_bytes()
    for i in range(len(b)):
        t.append(b[i])
    t.append(0)
    return at


def _elf() -> List[UInt8]:
    """A minimal 64-bit little-endian ELF shared object whose dynamic section
    says NEEDED libc.so.6, SONAME libkomira_alpha_native.so.1, RUNPATH
    $ORIGIN, FLAGS DF_SYMBOLIC (test_native_install.mojo's, one NEEDED)."""
    var strtab = List[UInt8]()
    strtab.append(0)
    var tags: List[Int] = [1, 14, 29, 30, 0]
    var vals = List[Int]()
    vals.append(_str_at(strtab, String("libc.so.6")))
    vals.append(_str_at(strtab, String("libkomira_alpha_native.so.1")))
    vals.append(_str_at(strtab, String("$ORIGIN")))
    vals.append(0x2)
    vals.append(0)
    var str_off = 64
    var dyn_off = (str_off + len(strtab) + 7) // 8 * 8
    var sh_off = dyn_off + 16 * len(tags)
    var b = List[UInt8]()
    for _ in range(sh_off + 3 * 64):
        b.append(0)
    b[0] = 0x7F
    b[1] = 0x45
    b[2] = 0x4C
    b[3] = 0x46
    b[4] = 2
    b[5] = 1
    b[6] = 1
    _put(b, 0x10, 3, 2)
    _put(b, 0x12, 0x3E, 2)
    _put(b, 0x14, 1, 4)
    _put(b, 0x28, sh_off, 8)
    _put(b, 0x34, 64, 2)
    _put(b, 0x3A, 64, 2)
    _put(b, 0x3C, 3, 2)
    for i in range(len(strtab)):
        b[str_off + i] = strtab[i]
    for i in range(len(tags)):
        _put(b, dyn_off + 16 * i, tags[i], 8)
        _put(b, dyn_off + 16 * i + 8, vals[i], 8)
    _put(b, sh_off + 64 + 4, 3, 4)
    _put(b, sh_off + 64 + 0x18, str_off, 8)
    _put(b, sh_off + 64 + 0x20, len(strtab), 8)
    _put(b, sh_off + 128 + 4, 6, 4)
    _put(b, sh_off + 128 + 0x18, dyn_off, 8)
    _put(b, sh_off + 128 + 0x20, 16 * len(tags), 8)
    _put(b, sh_off + 128 + 0x28, 1, 4)
    return b^


def _write_bytes(path: String, b: List[UInt8]) raises:
    var f = open(path, "w")
    f.write_bytes(b)
    f.close()


struct Played(ProcessRunner):
    """kci_build's ScriptedRunner, and after every `pixi install` the .so and
    its link in the environment's lib/ (bytes and a symbolic link, which a
    step's text files cannot be).

    Layout: owned values only. No pointer field."""

    var inner: ScriptedRunner
    var so: List[UInt8]

    def __init__(out self, var so: List[UInt8]):
        self.inner = ScriptedRunner()
        self.so = so^

    def run(mut self, spec: RunSpec) raises -> RunResult:
        var r = self.inner.run(spec)
        if len(spec.argv) > 0 and spec.argv[0] == String("install"):
            var lib = spec.cwd + String("/") + String(ENV) + String("/lib")
            makedirs(lib, exist_ok=True)
            var so = spec.cwd + String("/") + String(ENV) + String("/") + String(SO)
            _write_bytes(so, self.so)
            _chmod(so, Int32(0o755))
            symlink(String("libkomira_alpha_native.so.1"), spec.cwd + String("/") + String(ENV) + String("/") + String(LINK))
        return r^


def _lib_row(kind: String, path: String, sha: String) -> String:
    return String('{"kind":"') + kind + String('","path":"') + path + String('","sha256":"') + sha + String('"}')


struct Fx(Movable):
    """komira_alpha shipping the .so, the request validating it alone."""

    var release: ExampleRelease
    var req: ValidateRequest
    var host: EnvHost
    var so: List[UInt8]

    def __init__(out self, sub: String, codec_only: Bool = False) raises:
        """`codec_only`: komira_alpha ships no native file, has `dlopen`
        rows for liblz4.so.1 and lacks its `lz4-c` requirement (the planted
        defect of slice 4), and its README has no link block."""
        var root = _tmp(sub)
        var so = _elf()
        _write_bytes(root + String("/so"), so)
        var so_sha = file_sha256_hex(root + String("/so"))
        var r = ExampleRelease()
        r.set_meta(
            String("komira_alpha"), String("doc_files"),
            String('[{"path":"share/doc/komira_alpha/README.md","sha256":"')
            + _sha(String(README_CODEC) if codec_only else String(README)) + String('"}]'),
        )
        if codec_only:
            r.set_meta(String("komira_alpha"), String("dlopen"), String(LZ4_ROW))
            r.set_meta(
                String("komira_alpha"), String("depends"), String('["__linux","mojo-compiler ==') + r.version + String('"]')
            )
        else:
            r.set_meta(
                String("komira_alpha"), String("lib_files"),
                String("[") + _lib_row(String("link"), String(LINK), so_sha) + String(",")
                + _lib_row(String("shared"), String(SO), so_sha) + String("]"),
            )
            r.set_meta(
                String("komira_alpha"), String("depends"),
                String('["__linux","mojo-compiler ==') + r.version + String('","__glibc >=2.34"]'),
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
        req.stage = String("beta")
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
        self.host = EnvHost(root + String("/etc_pixi"))
        self.release = r^
        self.req = req^
        self.so = so^

    def work(self) -> String:
        return self.req.scratch_dir + String("/install-env/work")

    def env(self) -> String:
        return self.work() + String("/") + String(ENV)

    def openssl_work(self) -> String:
        return self.req.scratch_dir + String("/install-env/openssl/work")


def _alpha_record(fx: Fx) -> String:
    var r = fx.release.copy()
    var b = r.build()
    return (
        String('{"name":"komira_alpha","version":"') + r.version + String('","build":"') + b + String('","sha256":"')
        + r.sha256_of(String("komira_alpha")) + String('","url":"') + String(CHANNEL) + String("/linux-64/")
        + r.file_name(String("komira_alpha")) + String('","files":["') + String(LINK) + String('","') + String(SO)
        + String('","lib/mojo/komira_alpha.mojoc","share/doc/komira_alpha/README.md"]}')
    )


def _record_name(fx: Fx) -> String:
    return (
        String(ENV) + String("/conda-meta/komira_alpha-") + fx.release.version + String("-") + fx.release.build()
        + String(".json")
    )


def _compiler_record() -> String:
    return (
        String('{"name":"mojo-compiler","version":"1.0.0","build":"release","sha256":"')
        + String("4444444444444444444444444444444444444444444444444444444444444444")
        + String('","url":"') + String(COMPILER) + String('/linux-64/mojo-compiler-1.0.0-release.conda"}')
    )


def _trace(lib_dir: String) -> String:
    """A loader record: the komira .so from `lib_dir`."""
    return (
        String("     100:\tcalling init: /lib/x86_64-linux-gnu/libc.so.6\n     100:\tcalling init: ") + lib_dir
        + String("/libkomira_alpha_native.so.1\n")
    )


def _run_words(fx: Fx) -> List[String]:
    var w: List[String] = [String("-Xlinker"), String("-L") + fx.env() + String("/lib"), String("-Xlinker"), String("-lkomira_alpha_native")]
    return w^


struct Script(Copyable, Movable):
    """What the played runs answer: the README record's lib/ directory, the
    load program's stdout and exit, the openssl program's."""

    var readme_lib: String
    var load_out: String
    var load_exit: Int32
    var openssl_out: String
    var openssl_exit: Int32

    def __init__(out self, fx: Fx):
        self.readme_lib = fx.env() + String("/lib")
        self.load_out = String("LOADED ") + fx.env() + String("/") + String(SO) + String("\n")
        self.load_exit = Int32(0)
        self.openssl_out = String("OPENSSL ok\n")
        self.openssl_exit = Int32(0)


def _played(fx: Fx, s: Script) -> Played:
    var p = Played(fx.so.copy())
    # 1. the whole install
    var install = ScriptedStep(install_env_argv(fx.work()), exit_code=Int32(0), stderr_text=String("installed\n"))
    install.writes(_record_name(fx), _alpha_record(fx))
    install.writes(String(ENV) + String("/conda-meta/mojo-compiler-1.0.0-release.json"), _compiler_record())
    install.writes(String(ENV) + String("/share/doc/komira_alpha/README.md"), String(README))
    install.writes(String(ENV) + String("/lib/mojo/komira_alpha.mojoc"), String("komira_alpha"))
    p.inner.expect(install^)
    # 2. the README run, under the loader's record
    var readme = ScriptedStep(run_program_argv(fx.work(), String(PROGRAM), _run_words(fx)), stdout_text=String(COUNT))
    readme.writes(String("out/readme_komira_alpha.ld.100"), _trace(s.readme_lib))
    p.inner.expect(readme^)
    # 3. mojo build with the block's build words, then the built program
    var build_words = _run_words(fx)
    for w in [String("-Xlinker"), String("-rpath"), String("-Xlinker"), String("$ORIGIN/../lib")]:
        build_words.append(w.copy())
    p.inner.expect(
        ScriptedStep(build_program_argv(fx.work(), String(PROGRAM), build_words, fx.env() + String("/bin/readme_komira_alpha")))
    )
    var built = ScriptedStep(List[String](), stdout_text=String(COUNT))
    built.writes(String("out/built_readme_komira_alpha.ld.101"), _trace(fx.env() + String("/lib")))
    p.inner.expect(built^)
    # 4. the load program
    p.inner.expect(
        ScriptedStep(run_program_argv(fx.work(), String("native_load.mojo")), exit_code=s.load_exit, stdout_text=s.load_out.copy())
    )
    # 7. the openssl environment and its one program
    var ossl = ScriptedStep(install_env_argv(fx.openssl_work()), exit_code=Int32(0))
    ossl.writes(_record_name(fx), _alpha_record(fx))
    ossl.writes(String(ENV) + String("/lib/libssl.so.3"), String("the system's libssl, played"))
    p.inner.expect(ossl^)
    p.inner.expect(
        ScriptedStep(
            run_program_argv(fx.openssl_work(), String("openssl_1.mojo")), exit_code=s.openssl_exit,
            stdout_text=s.openssl_out.copy(), stderr_text=String("SSL_CTX_new returned NULL\n") if s.openssl_exit != 0 else String(""),
        )
    )
    return p^


def _transport(fx: Fx) -> ScriptedPkgTransport:
    var t = ScriptedPkgTransport()
    t.queue(_resp(200))
    t.queue(_resp(404))
    var r = fx.release.copy()
    var index = String('{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{')
    var first = True
    for name in [String("komira_alpha"), String("komira_beta"), String("komira")]:
        if not first:
            index += String(",")
        first = False
        index += String('"') + r.file_name(name) + String('":{"sha256":"') + r.sha256_of(name) + String('","size":1}')
    t.queue(_resp(200, index + String("}}")))
    t.queue(_resp(200, String("alpha conda bytes")))
    return t^


def _resp(status: Int, body: String = String("")) -> PkgResponse:
    var r = PkgResponse(status)
    var b = List[UInt8]()
    var s = body.as_bytes()
    for i in range(len(s)):
        b.append(s[i])
    r.with_body(b^)
    return r^


def _validate(fx: Fx, s: Script, mut p: Played) raises -> ResultValidation:
    var t = _transport(fx)
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    return run_install_env(p, t, sl, log, fx.req, fx.host)


def _failed(row: ResultValidation) -> String:
    var s = String("")
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            if s.byte_length() > 0:
                s += String("|")
            s += row.checks[i].check + String(": ") + row.checks[i].got
    return s^


def _order(row: ResultValidation) -> String:
    var out = String("")
    for i in range(len(row.checks)):
        if i > 0:
            out += String(" ")
        out += row.checks[i].check
    return out^


def _env_has(spec: RunSpec, entry: String) -> Bool:
    if not Bool(spec.env):
        return False
    ref e = spec.env.value()
    for i in range(len(e)):
        if e[i] == entry:
            return True
    return False


def _env_has_prefix(spec: RunSpec, prefix: String) -> Bool:
    if not Bool(spec.env):
        return False
    ref e = spec.env.value()
    for i in range(len(e)):
        if e[i].startswith(prefix):
            return True
    return False


# ---- (0) the pass ---------------------------------------------------------------


def test_every_native_row_runs_and_passes() raises:
    var fx = Fx(String("pass"))
    var s = Script(fx)
    var p = _played(fx, s)
    var row = _validate(fx, s, p)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(
        _order(row),
        String("release network channel channel host scratch pixi install readme payload program loaded_from")
        + String(" lib_files glibc needed symbolic built loaded_from load openssl"),
    )
    assert_equal(p.inner.remaining(), 0)
    # the README run: the loader's record on, LD_LIBRARY_PATH unset
    ref readme = p.inner.calls[1]
    assert_true(_env_has(readme, String("LD_DEBUG=libs")))
    assert_true(_env_has(readme, String("LD_DEBUG_OUTPUT=") + fx.work() + String("/out/readme_komira_alpha.ld")))
    assert_false(_env_has_prefix(readme, String("LD_LIBRARY_PATH=")))
    # the built program is the environment's bin/readme_komira_alpha
    assert_equal(p.inner.calls[3].path, fx.env() + String("/bin/readme_komira_alpha"))
    assert_true(_env_has(p.inner.calls[3], String("LD_DEBUG=libs")))
    # the load program: every installed shared row, RTLD_NOW
    var so_path = fx.env() + String("/") + String(SO)
    var paths: List[String] = [so_path.copy()]
    var text = open(fx.work() + String("/native_load.mojo"), "r").read()
    assert_equal(text, load_program_text(paths))
    assert_true(text.find(String("RTLD.NOW")) >= 0, text)
    assert_true(text.find(String('String("') + so_path + String('")')) >= 0, text)
    # the openssl environment requires conda-forge's openssl 3.*, and its
    # program opens the owner, then the system libssl, both RTLD_GLOBAL
    var manifest = open(fx.openssl_work() + String("/pixi.toml"), "r").read()
    assert_true(manifest.find(String('openssl = { version = "3.*", channel = "conda-forge" }')) >= 0, manifest)
    # komira_alpha requires `__glibc >=2.34`: every environment pixi solves
    # declares the platform's glibc floor, or pixi assumes its own default
    # (2.28 on linux-64) and finds no candidate (kci run 38273977963)
    var floor = glibc_floor_of(String("linux-64"))
    assert_true(floor.byte_length() > 0)
    assert_equal(String("__glibc >=") + floor, String("__glibc >=2.34"))
    var want = String('\n[system-requirements]\nlibc = { family = "glibc", version = "') + floor + String('" }\n')
    var whole = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(whole.find(want) >= 0, whole)
    assert_true(manifest.find(want) >= 0, manifest)
    var ossl = open(fx.openssl_work() + String("/openssl_1.mojo"), "r").read()
    assert_true(ossl.find(String("RTLD.NOW | RTLD.GLOBAL")) >= 0, ossl)
    assert_true(ossl.find(fx.openssl_work() + String("/") + String(ENV) + String("/lib/libssl.so.3")) >= 0, ossl)
    assert_true(ossl.find(String('"SSL_CTX_new"')) >= 0, ossl)
    # the openssl environment reuses the whole set's pixi cache
    assert_equal(p.inner.calls[5].cwd, fx.openssl_work())
    assert_true(_env_has(p.inner.calls[5], String("PIXI_CACHE_DIR=") + fx.work() + String("/cache")))


# ---- (b) row 4 red on an unresolved symbol ----------------------------------------


def test_an_unresolved_symbol_makes_the_load_row_red() raises:
    var fx = Fx(String("unresolved"))
    var s = Script(fx)
    var so_path = fx.env() + String("/") + String(SO)
    # what dlopen(RTLD_NOW) says of a .so referencing a name nothing defines
    s.load_out = (
        String("FAILED ") + so_path + String(": dlopen failed: ") + so_path
        + String(": undefined symbol: komira_alpha_missing\n")
    )
    s.load_exit = Int32(1)
    var p = _played(fx, s)
    var row = _validate(fx, s, p)
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    var failed = _failed(row)
    assert_true(failed.startswith(String("load: load: the whole set: ")), failed)
    assert_true(failed.find(String("undefined symbol: komira_alpha_missing")) >= 0, failed)
    assert_true(failed.find(String("|")) < 0, String("only the load row fails: ") + failed)
    assert_equal(p.inner.remaining(), 0)


# ---- (5) loaded from outside the environment ------------------------------------


def test_a_komira_so_loaded_from_outside_the_environment_is_red() raises:
    var fx = Fx(String("outside"))
    var s = Script(fx)
    s.readme_lib = String("/usr/lib")
    var p = _played(fx, s)
    var row = _validate(fx, s, p)
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    var failed = _failed(row)
    assert_true(failed.startswith(String("loaded_from: loaded_from: readme_komira_alpha: ")), failed)
    assert_true(failed.find(String("libkomira_alpha_native.so.1 was loaded from /usr/lib/")) >= 0, failed)


# ---- (7) the system OpenSSL beside an owner ---------------------------------------


def test_a_failing_openssl_program_is_red() raises:
    var fx = Fx(String("openssl"))
    var s = Script(fx)
    s.openssl_out = String("")
    s.openssl_exit = Int32(1)
    var p = _played(fx, s)
    var row = _validate(fx, s, p)
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    var failed = _failed(row)
    assert_true(failed.startswith(String("openssl: openssl: libkomira_alpha_native.so.1 beside the system OpenSSL: exit 1")), failed)
    assert_true(failed.find(String("SSL_CTX_new returned NULL")) >= 0, failed)


# ---- which packages get an environment of their own -------------------------------


def _pin(name: String, library: Bool, lib_files: Bool, depends: String = String(""), dlopen: Bool = False) -> InstallPin:
    var p = InstallPin(name.copy())
    p.is_library = library
    p.has_lib_files = lib_files
    p.has_dlopen = dlopen
    if depends.byte_length() > 0:
        p.depends.append(depends.copy())
    return p^


def test_each_native_member_of_a_set_is_installed_alone() raises:
    var named = List[InstallPin]()
    named.append(_pin(String("komira"), False, False))
    var pins = List[InstallPin]()
    pins.append(_pin(String("komira"), False, False))
    pins.append(_pin(String("komira_alpha"), True, True))
    pins.append(_pin(String("komira_lz4"), True, False, String("lz4-c >=1.9.3,<2"), dlopen=True))
    pins.append(_pin(String("komira_plain"), True, False, String("__linux")))
    # dlopen rows and no requirement: the defect the alone row is for
    pins.append(_pin(String("komira_zlib"), True, False, String("__linux"), dlopen=True))
    var got = alone_pins(named, pins)
    assert_equal(len(got), 3)
    assert_equal(got[0], 1)
    assert_equal(got[1], 2)
    assert_equal(got[2], 4)
    # one native package installed by itself needs no second environment
    var one = List[InstallPin]()
    one.append(_pin(String("komira_alpha"), True, True))
    assert_equal(len(alone_pins(one, one)), 0)


def test_the_generated_programs_are_the_ones_the_build_compiles() raises:
    # tests/generated/ holds one of each; BUCK builds them (native_load_example,
    # openssl_example), so what kci writes is held to compiling Mojo
    var owner = String("/env/lib/libkomira_example_native.so.1")
    var paths: List[String] = [owner.copy()]
    assert_equal(open(data_path(String("native_load_example.mojo")), "r").read(), load_program_text(paths))
    assert_equal(
        open(data_path(String("openssl_example.mojo")), "r").read(),
        openssl_program_text(owner, String("/env/lib/libssl.so.3")),
    )


def _lf(kind: String, path: String, sha: String) -> LibFile:
    var f = LibFile()
    f.kind = kind.copy()
    f.path = path.copy()
    f.sha256_hex = sha.copy()
    return f^


def _plain_record() -> String:
    return (
        String('{"name":"komira_alpha","version":"1.0.0","build":"h0_1","files":["') + String(LINK) + String('","')
        + String(SO) + String('"]}')
    )


def test_a_native_member_of_a_set_is_checked_alone() raises:
    var root = _tmp(String("set"))
    var so = _elf()
    _write_bytes(root + String("/so"), so)
    var sha = file_sha256_hex(root + String("/so"))
    var alpha = InstallPin(String("komira_alpha"))
    alpha.version = String("1.0.0")
    alpha.build = String("h0_1")
    alpha.subdir = String("linux-64")
    alpha.is_library = True
    alpha.import_name = String("komira_alpha")
    alpha.has_lib_files = True
    alpha.lib_files.append(_lf(String("link"), String(LINK), sha))
    alpha.lib_files.append(_lf(String("shared"), String(SO), sha))
    alpha.depends.append(String("__glibc >=2.34"))
    var meta = InstallPin(String("komira"))
    meta.version = String("1.0.0")
    meta.build = String("h0_1")
    meta.subdir = String("linux-64")
    var named = List[InstallPin]()
    named.append(meta.copy())
    var pins = List[InstallPin]()
    pins.append(meta.copy())
    pins.append(alpha.copy())
    # the whole set's environment, as its install left it
    var dir = root + String("/install-set")
    var work = dir + String("/work")
    var env = work + String("/") + String(ENV)
    makedirs(env + String("/conda-meta"), exist_ok=True)
    makedirs(env + String("/lib"), exist_ok=True)
    makedirs(work + String("/out"), exist_ok=True)
    write_text_file(env + String("/conda-meta/komira_alpha-1.0.0-h0_1.json"), _plain_record())
    _write_bytes(env + String("/") + String(SO), so)
    _chmod(env + String("/") + String(SO), Int32(0o755))
    symlink(String("libkomira_alpha_native.so.1"), env + String("/") + String(LINK))
    var program = ReadmeProgram()
    program.file = String(PROGRAM)
    program.text = String("the README runner, played\n")
    program.package = String("komira_alpha")
    program.display = String("src/komira_alpha/README.md")
    var programs = List[ReadmeProgram]()
    programs.append(program^)
    # no conda-forge: row 7 has nowhere to get the system OpenSSL from
    var v = StageValidation(7)
    v.name = String("install-set")
    v.kind = String(VALIDATION_KIND_CONDA_INSTALL_ENV)
    v.installs.append(String("komira"))
    v.compiler_channel = String(COMPILER)
    var p = Played(so.copy())
    p.inner.expect(
        ScriptedStep(run_program_argv(work, String("native_load.mojo")), stdout_text=String("LOADED ") + env + String("/") + String(SO) + String("\n"))
    )
    var awork = dir + String("/alone/komira_alpha/work")
    var aenv = awork + String("/") + String(ENV)
    var install = ScriptedStep(install_env_argv(awork))
    install.writes(String(ENV) + String("/conda-meta/komira_alpha-1.0.0-h0_1.json"), _plain_record())
    p.inner.expect(install^)
    p.inner.expect(
        ScriptedStep(run_program_argv(awork, String("native_load.mojo")), stdout_text=String("LOADED ") + aenv + String("/") + String(SO) + String("\n"))
    )
    var readme = ScriptedStep(run_program_argv(awork, String(PROGRAM), List[String]()), stdout_text=String(COUNT))
    readme.writes(String("out/readme_komira_alpha.ld.102"), _trace(aenv + String("/lib")))
    p.inner.expect(readme^)
    var checks = List[ResultValidationCheck]()
    run_native_rows(p, v, String(CHANNEL), String("1.0.0"), dir, named, pins, programs, checks)
    assert_equal(p.inner.remaining(), 0)
    var order = String("")
    var failed = String("")
    for i in range(len(checks)):
        if i > 0:
            order += String(" ")
        order += checks[i].check
        if not checks[i].ok:
            failed += checks[i].got
    assert_equal(order, String("lib_files glibc needed symbolic load alone load loaded_from openssl"))
    assert_true(failed.startswith(String("openssl: the validation declares no conda-forge channel")), failed)
    assert_true(checks[len(checks) - 1].got == failed)
    # alone: its own manifest, naming komira_alpha and not the metapackage;
    # the whole set's pixi cache
    var manifest = open(awork + String("/pixi.toml"), "r").read()
    assert_true(manifest.find(String("komira_alpha = {")) >= 0, manifest)
    assert_true(manifest.find(String("komira = {")) < 0, manifest)
    assert_true(
        manifest.find(
            String('\n[system-requirements]\nlibc = { family = "glibc", version = "')
            + glibc_floor_of(String("linux-64")) + String('" }\n')
        ) >= 0,
        manifest,
    )
    assert_true(_env_has(p.inner.calls[1], String("PIXI_CACHE_DIR=") + work + String("/cache")))
    assert_true(_env_has(p.inner.calls[3], String("LD_DEBUG_OUTPUT=") + awork + String("/out/readme_komira_alpha.ld")))


# ---- (codec) a package that opens a system codec and ships no native file ---------


comptime LZ4_TRACE: String = (
    "     103:\tcalling init: /lib/x86_64-linux-gnu/libc.so.6\n"
    "     103:\tcalling init: /usr/lib/x86_64-linux-gnu/liblz4.so.1\n"
)


def test_a_codec_package_without_its_requirement_is_native() raises:
    # metadata.json's dlopen rows make komira_alpha native although its
    # depends lack lz4-c: the README run is under the loader's record, and
    # the codec loaded from /usr/lib makes loaded_from red
    var fx = Fx(String("codec"), codec_only=True)
    var p = Played(fx.so.copy())
    var install = ScriptedStep(install_env_argv(fx.work()), exit_code=Int32(0), stderr_text=String("installed\n"))
    install.writes(_record_name(fx), _alpha_record(fx))
    install.writes(String(ENV) + String("/conda-meta/mojo-compiler-1.0.0-release.json"), _compiler_record())
    install.writes(String(ENV) + String("/share/doc/komira_alpha/README.md"), String(README_CODEC))
    install.writes(String(ENV) + String("/lib/mojo/komira_alpha.mojoc"), String("komira_alpha"))
    p.inner.expect(install^)
    var readme = ScriptedStep(run_program_argv(fx.work(), String(PROGRAM), List[String]()), stdout_text=String(COUNT))
    readme.writes(String("out/readme_komira_alpha.ld.103"), String(LZ4_TRACE))
    p.inner.expect(readme^)
    var row = _validate(fx, Script(fx), p)
    assert_equal(p.inner.remaining(), 0)
    assert_equal(
        _order(row), String("release network channel channel host scratch pixi install readme payload program loaded_from")
    )
    assert_equal(
        _failed(row),
        String("loaded_from: loaded_from: readme_komira_alpha: liblz4.so.1 was loaded from /usr/lib/x86_64-linux-gnu/liblz4.so.1, not from ")
        + fx.env() + String("/lib/"),
    )


def _codec_alone(sub: String, var depends: List[String]) raises -> List[ResultValidationCheck]:
    """`run_native_rows` for a set whose member komira_lz4 ships no native
    file and has dlopen rows (`depends` its requirements); its README, run
    alone, loads liblz4.so.1 from /usr/lib."""
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
    var named = List[InstallPin]()
    named.append(meta.copy())
    var pins = List[InstallPin]()
    pins.append(meta.copy())
    pins.append(lz4^)
    var dir = root + String("/install-set")
    makedirs(dir + String("/work/out"), exist_ok=True)
    var program = ReadmeProgram()
    program.file = String("readme_komira_lz4.mojo")
    program.text = String("the README runner, played\n")
    program.package = String("komira_lz4")
    program.display = String("src/komira_lz4/README.md")
    var programs = List[ReadmeProgram]()
    programs.append(program^)
    var v = StageValidation(7)
    v.name = String("install-set")
    v.kind = String(VALIDATION_KIND_CONDA_INSTALL_ENV)
    v.installs.append(String("komira"))
    v.compiler_channel = String(COMPILER)
    var p = ScriptedRunner()
    var awork = dir + String("/alone/komira_lz4/work")
    var install = ScriptedStep(install_env_argv(awork))
    install.writes(String(ENV) + String("/conda-meta/komira_lz4-1.0.0-h0_1.json"), String('{"name":"komira_lz4"}'))
    p.expect(install^)
    var readme = ScriptedStep(run_program_argv(awork, String("readme_komira_lz4.mojo"), List[String]()), stdout_text=String(COUNT))
    readme.writes(String("out/readme_komira_lz4.ld.103"), String(LZ4_TRACE))
    p.expect(readme^)
    var checks = List[ResultValidationCheck]()
    run_native_rows(p, v, String(CHANNEL), String("1.0.0"), dir, named, pins, programs, checks)
    assert_equal(p.remaining(), 0)
    var order = String("")
    for i in range(len(checks)):
        if i > 0:
            order += String(" ")
        order += checks[i].check
    # no lib_files: no per-library rows, no build, no load; only alone
    assert_equal(order, String("alone loaded_from"))
    assert_true(checks[0].ok, checks[0].got)
    assert_false(checks[1].ok)
    assert_equal(
        checks[1].got,
        String("loaded_from: komira_lz4 alone: liblz4.so.1 was loaded from /usr/lib/x86_64-linux-gnu/liblz4.so.1, not from ")
        + awork + String("/") + String(ENV) + String("/lib/"),
    )
    return checks^


def test_a_codec_package_missing_its_requirement_is_red_alone() raises:
    # slice 4's planted defect: komira_lz4 without lz4-c, installed alone
    var depends: List[String] = [String("__linux")]
    _ = _codec_alone(String("codec-missing"), depends^)


def test_a_codec_only_package_loading_the_system_codec_is_red_alone() raises:
    # the requirement declared, the codec still loaded from /usr/lib
    var depends: List[String] = [String("__linux"), String("lz4-c >=1.9.3,<2")]
    _ = _codec_alone(String("codec-declared"), depends^)


def test_load_findings() raises:
    var paths: List[String] = [String("/e/lib/liba.so.1"), String("/e/lib/libb.so.1")]
    assert_equal(len(load_findings(String("LOADED /e/lib/liba.so.1\nLOADED /e/lib/libb.so.1\n"), paths, RunResult(Int32(0)), String(""))), 0)
    var missing = load_findings(String("LOADED /e/lib/liba.so.1\n"), paths, RunResult(Int32(0)), String(""))
    assert_equal(len(missing), 1)
    assert_equal(missing[0], String("/e/lib/libb.so.1 was not reported loaded"))
    var crashed = load_findings(String(""), List[String](), RunResult(Int32(1)), String("error: cannot compile\n"))
    assert_equal(len(crashed), 1)
    assert_true(crashed[0].startswith(String("the load program exit 1: ")), crashed[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
