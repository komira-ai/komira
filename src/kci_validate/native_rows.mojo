# =============================================================================
# src/kci_validate/native_rows.mojo -- beta's native install checks, run by a
#   CONDA_INSTALL_ENV validation (the kind `beta_validate` runs).
# =============================================================================
#
# docs/design/native_packaging.md, "Built once, promoted unchanged", rows 2
# to 7 (slice 11). A library pin is NATIVE when its metadata.json records
# native files it ships (`lib_files`) or system codecs it opens at run time
# (`dlopen`), whatever its requirements say: a package missing its codec's
# requirement is native, so its alone `loaded_from` row can go red. `run_install_env`
# (conda_install_env.mojo) runs these rows only when some installed pin is
# native: a release with none gets no row and runs nothing more. Every child
# runs with the validation's cleared environment (env.mojo), so
# LD_LIBRARY_PATH is unset throughout.
#
#   loaded_from  row 5. Each README program (step 4 of run_install_env, and
#                each built one below) runs with `loader_env`: LD_DEBUG=libs
#                and LD_DEBUG_OUTPUT=<w>/out/<record>.ld; every komira
#                object, and every system codec its library's closure
#                declares (`ReadmeProgram.codecs`, the closure's `dlopen`
#                sonames), it loaded must lie under <env>/lib, both paths
#                resolved (native_install.mojo `loaded_from_findings`). A
#                library the toolchain loads that no package declares
#                (libz, libzstd: the compiler's own) is not judged.
#   run_readme   how a README program runs, in step 4 and alone: `mojo run
#                <run args>`, except when `ReadmeProgram.runs_built`: its
#                closure ships a static archive (the block's build line
#                links komira_log's holder, which the JIT cannot load) or
#                opens a system codec (its `codecs`). Then `mojo build
#                <build args> -o <env>/bin/readme_<import>`, with no loader
#                record, and the built program run directly under it, both
#                reporting into the same stdout and stderr files (a compile
#                error is mapped to README lines as a run's is). A `mojo
#                run` record also holds the processes the compiler starts:
#                on a fresh environment's first run one loads libz.so.1 from
#                the system, which a codec's row would take for the
#                program's own `dlopen`.
#   lib_files glibc needed symbolic
#                rows 2 and 3 and build check 6 on the installed bytes
#                (native_install.mojo `check_native_install`), per pin with
#                `lib_files`.
#   built        row 6. For each README whose library's closure links native
#                files (a decision, docs/design/native_packaging.md install
#                check 6: a README with no link block is not built): `mojo build <build args> <w>/readme_<import>.mojo -o
#                <env>/bin/readme_<import>` (the README block's `build` words,
#                `$CONDA_PREFIX` replaced), then the built program run
#                directly, its count read as a README run's is; its loader
#                record is a `loaded_from` row.
#   load         row 4, in the whole set. <w>/native_load.mojo, generated from
#                every installed `shared` row (`load_program_text`), opens each
#                with dlopen RTLD_NOW, so an undefined symbol fails now however
#                the .so was linked. It prints `LOADED <path>` or
#                `FAILED <path>: <loader error>` per row; the row fails on a
#                FAILED line, on a path it did not report, and on a run that
#                did not exit 0.
#   alone        rows 4 and 5 per package. For each native pin the validation
#                does not already install by itself (`alone_pins`), a second
#                environment, <scratch>/<validation>/alone/<name>/, holding
#                only that package and its own requirements (the `alone` row:
#                its install), where the load program runs over every shared
#                row installed there and the package's README runs with the
#                loader record. A requirement the package forgot is red here
#                even when another package of the set installs it.
#   openssl      row 7. When any shared row is installed: one more
#                environment, <scratch>/<validation>/openssl/, holding the
#                validation's installs and conda-forge's `openssl 3.*` (the
#                extra requirement of this environment only). For each
#                installed shared row a program (`openssl_program_text`)
#                opens it RTLD_NOW|RTLD_GLOBAL, then the system libssl.so.3
#                the same way, and calls TLS_method and SSL_CTX_new: an owner
#                exporting an unprefixed OpenSSL name interposes on the
#                system's, which then fails or crashes. The design names the
#                owners of komira_http_core's closure; every owner is checked,
#                which includes them.
#
# The alone and openssl environments share the whole set's pixi cache
# (PIXI_CACHE_DIR), so the compiler and the release download once.
#
# The generated programs compile on every build: tests/generated/ holds one of
# each, built by this package's BUCK (`native_load_example`,
# `openssl_example`) and held byte-equal to what the two functions write by
# tests/test_native_rows.mojo.
#
# A failed install, program or record is a failed row, never a raise, and
# the rows after it still run.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import makedirs
from std.os.path import exists

from kci_api import ResultValidationCheck
from kci_build.runner import ProcessRunner, RunResult, RunSpec
from kci_release_machine import StageValidation
from kci_release_set.conda_metadata import LIB_KIND_SHARED

from .container import MANIFEST_NAME, install_manifest_text, join_path, work_subdirs
from .env import (
    AUTH_FILE,
    AUTH_FILE_TEXT,
    ENV_INSTALL_TIMEOUT_S,
    ENV_RUN_TIMEOUT_S,
    PIXI_LINK_DIR,
    PIXI_NAME,
    build_program_argv,
    env_child_env,
    env_records_dir,
    install_env_argv,
    run_program_argv,
)
from .native_install import CHECK_LOADED_FROM, check_native_install, loaded_from_findings, loader_env, loader_record
from .readback import check_program, read_or_empty, tail_lines
from .readme_installed import ReadmeProgram
from .readme_link import build_link_args, run_link_args
from .request import InstallPin

comptime CHECK_BUILT: String = "built"
comptime CHECK_LOAD: String = "load"
comptime CHECK_ALONE: String = "alone"
comptime CHECK_OPENSSL: String = "openssl"
comptime LOAD_PROGRAM: String = "native_load.mojo"
comptime LOADED_PREFIX: String = "LOADED "
comptime FAILED_PREFIX: String = "FAILED "
comptime OPENSSL_OK: String = "OPENSSL ok"
comptime OPENSSL_PACKAGE: String = "openssl"
comptime OPENSSL_VERSION: String = "3.*"
comptime OPENSSL_CHANNEL: String = "conda-forge"
comptime LIBSSL: String = "lib/libssl.so.3"
comptime LOADER_RECORD_SUFFIX: String = ".ld"


def is_native(pin: InstallPin) -> Bool:
    """A library pin shipping native files or opening a system codec: its
    metadata.json has `lib_files` or `dlopen` rows (file header). Never its
    requirements: the package that forgot its codec's requirement is the
    one the alone `loaded_from` row is for."""
    return pin.is_library and (pin.has_lib_files or pin.has_dlopen)


def any_native(pins: List[InstallPin]) -> Bool:
    for i in range(len(pins)):
        if is_native(pins[i]):
            return True
    return False


def is_installed(env_dir: String, pin: InstallPin) -> Bool:
    """`pin` at its version and build has a conda-meta record in `env_dir`."""
    return exists(
        join_path(env_dir, String("conda-meta/") + pin.name + String("-") + pin.version + String("-") + pin.build + String(".json"))
    )


def shared_paths(env_dir: String, pins: List[InstallPin]) -> List[String]:
    """The absolute path of every `shared` row of each pin installed in
    `env_dir`, in pin order."""
    var out = List[String]()
    for i in range(len(pins)):
        ref pin = pins[i]
        if not pin.is_library or not pin.has_lib_files or not is_installed(env_dir, pin):
            continue
        for k in range(len(pin.lib_files)):
            if pin.lib_files[k].kind == LIB_KIND_SHARED:
                out.append(join_path(env_dir, pin.lib_files[k].path))
    return out^


def alone_pins(named: List[InstallPin], pins: List[InstallPin]) -> List[Int]:
    """The native pins that get an environment of their own (file header,
    `alone`): every one, except the one package a validation that installs
    exactly one package already installs by itself."""
    var out = List[Int]()
    var by_itself = len(named) == 1 and len(pins) == 1
    for i in range(len(pins)):
        if not is_native(pins[i]):
            continue
        if by_itself and pins[i].name == named[0].name:
            continue
        out.append(i)
    return out^


def _literal(s: String) raises -> String:
    """A Mojo expression for the String `s`. RAISES on a control byte: no
    path kci writes into a program holds one."""
    var b = s.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) < 32 or Int(b[i]) == 127:
            raise Error(String("the path '") + s + String("' holds a control character; kci writes no such path into a program"))
    return String('String("') + s.replace(String("\\"), String("\\\\")).replace(String('"'), String('\\"')) + String('")')


def load_program_text(paths: List[String]) raises -> String:
    """The load program (file header, `load`) over `paths`."""
    var listed = String("")
    for i in range(len(paths)):
        if i > 0:
            listed += String(",\n")
        listed += String("        ") + _literal(paths[i])
    listed += String("\n")
    var t = String("# Written by kci: the native install check `load` (row 4 of docs/design/native_packaging.md).\n")
    t += String("# Each installed shared library is opened with RTLD_NOW, so an undefined symbol fails at load.\n")
    t += String("from std.ffi import OwnedDLHandle, RTLD\n\n\n")
    t += String("def main() raises:\n")
    t += String("    var paths: List[String] = [\n") + listed + String("    ]\n")
    t += String("    var failed = 0\n")
    t += String("    for i in range(len(paths)):\n")
    t += String("        try:\n")
    t += String("            _ = OwnedDLHandle(paths[i], RTLD.NOW | RTLD.LOCAL)\n")
    t += String('            print("') + String(LOADED_PREFIX) + String('" + paths[i])\n')
    t += String("        except e:\n")
    t += String("            failed += 1\n")
    t += String('            print("') + String(FAILED_PREFIX) + String('" + paths[i] + ": " + String(e))\n')
    t += String("    if failed > 0:\n")
    t += String('        raise Error(String(failed) + " of " + String(len(paths)) + " shared libraries did not load")\n')
    return t^


def openssl_program_text(owner: String, libssl: String) raises -> String:
    """The program of row 7 for the shared library `owner` beside the system
    OpenSSL `libssl` (file header, `openssl`)."""
    var t = String("# Written by kci: the native install check `openssl` (row 7 of docs/design/native_packaging.md).\n")
    t += String("# The owner is opened first, into the global scope, then the system OpenSSL: an owner exporting\n")
    t += String("# an unprefixed OpenSSL name would interpose on it.\n")
    t += String("from std.ffi import OwnedDLHandle, RTLD\n\n\n")
    t += String("def main() raises:\n")
    t += String("    var owner = OwnedDLHandle(") + _literal(owner) + String(", RTLD.NOW | RTLD.GLOBAL)\n")
    t += String("    var ssl = OwnedDLHandle(") + _literal(libssl) + String(", RTLD.NOW | RTLD.GLOBAL)\n")
    t += String('    var method = ssl.call["TLS_method", Int]()\n')
    t += String("    if method == 0:\n")
    t += String('        raise Error("TLS_method returned NULL")\n')
    t += String('    var ctx = ssl.call["SSL_CTX_new", Int](method)\n')
    t += String("    if ctx == 0:\n")
    t += String('        raise Error("SSL_CTX_new returned NULL")\n')
    t += String('    print("') + String(OPENSSL_OK) + String('")\n')
    t += String("    _ = owner^\n")
    return t^


def _has(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def load_findings(stdout: String, paths: List[String], r: RunResult, stderr: String) -> List[String]:
    """What the load program's report says against `paths` (file header,
    `load`)."""
    var out = List[String]()
    var loaded = List[String]()
    var failed = List[String]()
    var lines = stdout.split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.startswith(LOADED_PREFIX):
            loaded.append(String(line[byte = LOADED_PREFIX.byte_length() :]))
        elif line.startswith(FAILED_PREFIX):
            var said = String(line[byte = FAILED_PREFIX.byte_length() :])
            failed.append(said.copy())
            out.append(said^)
    for i in range(len(paths)):
        if _has(loaded, paths[i]):
            continue
        var reported = False
        for k in range(len(failed)):
            if failed[k].startswith(paths[i] + String(": ")):
                reported = True
        if not reported:
            out.append(paths[i] + String(" was not reported loaded"))
    if not r.ok() and len(out) == 0:
        out.append(String("the load program ") + r.describe() + String(": ") + tail_lines(stderr, 2))
    return out^


def _row(check: String, var expected: String, var got: String, ok: Bool) -> ResultValidationCheck:
    return ResultValidationCheck(check.copy(), expected^, got^, ok)


def _finding_row(check: String, var expected: String, findings: List[String], who: String, ok_text: String) -> ResultValidationCheck:
    var ok = len(findings) == 0
    var got = check + String(": ") + who + String(": ")
    if ok:
        got += ok_text
    else:
        got += String("; ").join(findings)
    return ResultValidationCheck(check.copy(), expected^, got^, ok)


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _exit_text(r: RunResult) -> String:
    if r.timed_out:
        return String("timed out\n")
    if r.signaled:
        return String("signal ") + String(Int(r.exit_code)) + String("\n")
    return String(Int(r.exit_code)) + String("\n")


def _record_of(file: String) -> String:
    """`readme_<import>` for `readme_<import>.mojo`."""
    if file.endswith(String(".mojo")):
        return String(file[byte = 0 : file.byte_length() - 5])
    return file.copy()


def _start[R: ProcessRunner](mut runner: R, var spec: RunSpec, var env: List[String]) -> RunResult:
    """Run `spec` with `env`; a run that cannot start is exit 127 with why."""
    try:
        spec.set_env(env^)
        return runner.run(spec)
    except e:
        return RunResult(Int32(127), stderr_tail=String("not started: ") + String(e))


def _why(r: RunResult, stderr_path: String) -> String:
    var tail = tail_lines(read_or_empty(stderr_path), 2)
    if tail.byte_length() == 0:
        tail = r.stderr_tail.copy()
    return r.describe() + String(": ") + tail


def readme_loaded_from_row(
    record_prefix: String, env_dir: String, who: String, codecs: List[String], mut checks: List[ResultValidationCheck]
):
    """Row 5 over the loader record a run left at `record_prefix`, judging
    the komira objects and the declared `codecs` (file header)."""
    var findings: List[String]
    try:
        findings = loaded_from_findings(loader_record(record_prefix), env_dir, codecs)
    except e:
        findings = List[String]()
        findings.append(String(e))
    checks.append(
        _finding_row(
            String(CHECK_LOADED_FROM),
            String("every komira object and declared system codec ") + who + String(" loaded lies under ") + env_dir + String("/lib"),
            findings, who, String("every komira object and declared system codec it loaded came from the environment's lib/"),
        )
    )


def run_readme[R: ProcessRunner](
    mut runner: R, pixi: String, work: String, env_dir: String, p: ReadmeProgram, env: List[String],
    run_env: List[String], stdout_path: String, stderr_path: String,
) raises -> RunResult:
    """README program `p` run in `work`'s environment `env_dir` (file header,
    `run_readme`): under `mojo run` with the block's run words, or, when
    `p.runs_built()`, built with the block's build words into
    `<env_dir>/bin/` (the build with `env`) and the built program run.
    The run gets `run_env`. Either way its stdout and stderr go to
    `stdout_path` and `stderr_path`; a failed build is the result. RAISES
    when a process cannot be started."""
    if not p.runs_built():
        var spec = RunSpec(
            pixi.copy(), run_program_argv(work, p.file, run_link_args(p.block, env_dir)), work.copy(), ENV_RUN_TIMEOUT_S,
            stdout_path.copy(), stderr_path.copy(),
        )
        spec.set_env(run_env.copy())
        return runner.run(spec)
    var bin = join_path(env_dir, String("bin"))
    makedirs(bin, exist_ok=True)
    var exe = join_path(bin, _record_of(p.file))
    var build = RunSpec(
        pixi.copy(), build_program_argv(work, p.file, build_link_args(p.block, env_dir), exe), work.copy(),
        ENV_RUN_TIMEOUT_S, stdout_path.copy(), stderr_path.copy(),
    )
    build.set_env(env.copy())
    var b = runner.run(build)
    if not b.ok():
        return b^
    var run = RunSpec(exe.copy(), List[String](), work.copy(), ENV_RUN_TIMEOUT_S, stdout_path.copy(), stderr_path.copy())
    run.set_env(run_env.copy())
    return runner.run(run)


def _env_sharing_cache(bin: String, work: String, dir: String) -> List[String]:
    """`env_child_env(bin, work)` with PIXI_CACHE_DIR the whole set's
    (`<dir>/work/cache`): a second environment reuses what the first
    downloaded (the compiler, the release) instead of fetching it again."""
    var env = env_child_env(bin, work)
    for i in range(len(env)):
        if env[i].startswith(String("PIXI_CACHE_DIR=")):
            env[i] = String("PIXI_CACHE_DIR=") + join_path(join_path(dir, String("work")), String("cache"))
    return env^


def _prepare(work: String, manifest: String) -> String:
    """"" when `work` holds its subdirectories, pixi.toml and auth.json."""
    try:
        makedirs(work, exist_ok=True)
        var subs = work_subdirs()
        for i in range(len(subs)):
            makedirs(join_path(work, subs[i]), exist_ok=True)
        _write(join_path(work, String(MANIFEST_NAME)), manifest)
        _write(join_path(work, String(AUTH_FILE)), String(AUTH_FILE_TEXT))
    except e:
        return String(e)
    return String("")


def _install[R: ProcessRunner](mut runner: R, pixi: String, work: String, env: List[String]) -> String:
    """`pixi install` in `work`: "" when it exited 0; why not, otherwise."""
    var out_dir = join_path(work, String("out"))
    var log = join_path(out_dir, String("install.log"))
    var r = _start(
        runner,
        RunSpec(pixi.copy(), install_env_argv(work), work.copy(), ENV_INSTALL_TIMEOUT_S, join_path(out_dir, String("install.stdout")), log.copy()),
        env.copy(),
    )
    if r.ok():
        return String("")
    return String("pixi install ") + _why(r, log)


def _load_row[R: ProcessRunner](
    mut runner: R, pixi: String, work: String, env: List[String], pins: List[InstallPin], who: String,
    mut checks: List[ResultValidationCheck],
):
    """Row 4 over every shared row installed in `work`'s environment."""
    var env_dir = env_records_dir(work)
    var paths = shared_paths(env_dir, pins)
    if len(paths) == 0:
        return
    var out_dir = join_path(work, String("out"))
    var stdout_path = join_path(out_dir, String("native_load.stdout"))
    var stderr_path = join_path(out_dir, String("native_load.stderr"))
    var findings = List[String]()
    try:
        _write(join_path(work, String(LOAD_PROGRAM)), load_program_text(paths))
        var r = _start(
            runner,
            RunSpec(pixi.copy(), run_program_argv(work, String(LOAD_PROGRAM)), work.copy(), ENV_RUN_TIMEOUT_S, stdout_path.copy(), stderr_path.copy()),
            env.copy(),
        )
        findings = load_findings(read_or_empty(stdout_path), paths, r, read_or_empty(stderr_path))
    except e:
        findings.append(String(e))
    checks.append(
        _finding_row(
            String(CHECK_LOAD),
            String("every installed shared library (") + who + String(") loads with dlopen RTLD_NOW"),
            findings, who, String(len(paths)) + String(" shared libraries loaded with RTLD_NOW"),
        )
    )


def _built_rows[R: ProcessRunner](
    mut runner: R, pixi: String, work: String, env: List[String], p: ReadmeProgram, mut checks: List[ResultValidationCheck]
):
    """Row 6 for README program `p`, then row 5 over the built program."""
    var env_dir = env_records_dir(work)
    var out_dir = join_path(work, String("out"))
    var stem = _record_of(p.file)
    var record = String("built_") + stem
    var exe = join_path(join_path(env_dir, String("bin")), stem)
    var expected = (
        String("mojo build of ") + p.file + String(" with its README's build arguments into the environment's bin/,")
        + String(" then run: it exits 0 and prints its full count")
    )
    var build_err = join_path(out_dir, record + String(".build.stderr"))
    try:
        makedirs(join_path(env_dir, String("bin")), exist_ok=True)
    except:
        pass
    var b = _start(
        runner,
        RunSpec(
            pixi.copy(), build_program_argv(work, p.file, build_link_args(p.block, env_dir), exe), work.copy(),
            ENV_RUN_TIMEOUT_S, join_path(out_dir, record + String(".build.stdout")), build_err.copy(),
        ),
        env.copy(),
    )
    if not b.ok():
        checks.append(_row(String(CHECK_BUILT), expected^, String("built: mojo build of ") + p.file + String(" ") + _why(b, build_err), False))
        return
    var prefix = join_path(out_dir, record + String(LOADER_RECORD_SUFFIX))
    var r = _start(
        runner,
        RunSpec(exe.copy(), List[String](), work.copy(), ENV_RUN_TIMEOUT_S, join_path(out_dir, record + String(".out")), join_path(out_dir, record + String(".err"))),
        loader_env(env, prefix),
    )
    try:
        _write(join_path(out_dir, record + String(".exit")), _exit_text(r))
    except:
        pass
    _ = check_program(out_dir, p.file, checks, record)
    ref last = checks[len(checks) - 1]
    last.check = String(CHECK_BUILT)
    last.expected = expected^
    last.got = String("built: ") + exe + String(": ") + last.got
    readme_loaded_from_row(prefix, env_dir, String("the built ") + stem, p.codecs, checks)


def _alone_rows[R: ProcessRunner](
    mut runner: R, v: StageValidation, channel_url: String, mojo_pin: String, dir: String, pins: List[InstallPin],
    at: Int, programs: List[ReadmeProgram], mut checks: List[ResultValidationCheck],
):
    """Rows 4 and 5 for `pins[at]` in an environment of its own."""
    ref pin = pins[at]
    var who = pin.name + String(" alone")
    var bin = join_path(dir, String(PIXI_LINK_DIR))
    var pixi = join_path(bin, String(PIXI_NAME))
    var work = join_path(join_path(dir, String("alone/") + pin.name), String("work"))
    var env = _env_sharing_cache(bin, work, dir)
    var one = List[InstallPin]()
    one.append(pin.copy())
    var why = _prepare(work, install_manifest_text(v, channel_url, pin.subdir, one, mojo_pin))
    if why.byte_length() == 0:
        why = _install(runner, pixi, work, env)
    var env_dir = env_records_dir(work)
    if why.byte_length() == 0 and not is_installed(env_dir, pin):
        why = String("the environment holds no record of ") + pin.name + String(" ") + pin.version + String(" ") + pin.build
    checks.append(
        _row(
            String(CHECK_ALONE),
            String("pixi install of ") + pin.name + String(" and its own requirements only, in ") + work,
            String("alone: ") + (who + String(": installed") if why.byte_length() == 0 else who + String(": ") + why),
            why.byte_length() == 0,
        )
    )
    if why.byte_length() > 0:
        return
    _load_row(runner, pixi, work, env, pins, who, checks)
    var out_dir = join_path(work, String("out"))
    for k in range(len(programs)):
        ref p = programs[k]
        if p.package != pin.import_name:
            continue
        var record = _record_of(p.file)
        var prefix = join_path(out_dir, record + String(LOADER_RECORD_SUFFIX))
        var err = join_path(out_dir, record + String(".stderr"))
        var wrote = String("")
        try:
            _write(join_path(work, p.file), p.text)
            for m in range(len(p.modules)):
                _write(join_path(work, p.modules[m].name), p.modules[m].text)
        except e:
            wrote = String(e)
        var r = RunResult(Int32(127), stderr_tail=String("not started: ") + wrote)
        if wrote.byte_length() == 0:
            try:
                r = run_readme(
                    runner, pixi, work, env_dir, p, env, loader_env(env, prefix), join_path(out_dir, record + String(".stdout")), err,
                )
            except e:
                r = RunResult(Int32(127), stderr_tail=String("not started: ") + String(e))
        if r.ok():
            readme_loaded_from_row(prefix, env_dir, who, p.codecs, checks)
        else:
            checks.append(
                _row(
                    String(CHECK_LOADED_FROM),
                    String("the README of ") + who + String(" runs, loading every komira object and codec from its environment"),
                    String("loaded_from: ") + who + String(": its README program ") + p.file + String(" ") + _why(r, err),
                    False,
                )
            )


def _openssl_rows[R: ProcessRunner](
    mut runner: R, v: StageValidation, channel_url: String, mojo_pin: String, dir: String, named: List[InstallPin],
    pins: List[InstallPin], mut checks: List[ResultValidationCheck],
):
    """Row 7 (file header, `openssl`)."""
    var expected_install = (
        String("pixi install of the validation's installs and ") + String(OPENSSL_CHANNEL) + String("'s ")
        + String(OPENSSL_PACKAGE) + String(" ") + String(OPENSSL_VERSION) + String(", with lib/libssl.so.3")
    )
    if not _has(v.extra_channels, String(OPENSSL_CHANNEL)):
        checks.append(
            _row(
                String(CHECK_OPENSSL), expected_install^,
                String("openssl: the validation declares no ") + String(OPENSSL_CHANNEL)
                + String(" channel, where the system OpenSSL of this row comes from"),
                False,
            )
        )
        return
    var bin = join_path(dir, String(PIXI_LINK_DIR))
    var pixi = join_path(bin, String(PIXI_NAME))
    var work = join_path(join_path(dir, String("openssl")), String("work"))
    var env = _env_sharing_cache(bin, work, dir)
    var manifest = install_manifest_text(v, channel_url, named[0].subdir, named, mojo_pin)
    manifest += (
        String(OPENSSL_PACKAGE) + String(' = { version = "') + String(OPENSSL_VERSION) + String('", channel = "')
        + String(OPENSSL_CHANNEL) + String('" }\n')
    )
    var why = _prepare(work, manifest)
    if why.byte_length() == 0:
        why = _install(runner, pixi, work, env)
    var env_dir = env_records_dir(work)
    var libssl = join_path(env_dir, String(LIBSSL))
    if why.byte_length() == 0 and not exists(libssl):
        why = String("the environment holds no ") + String(LIBSSL)
    if why.byte_length() > 0:
        checks.append(_row(String(CHECK_OPENSSL), expected_install^, String("openssl: ") + why, False))
        return
    var paths = shared_paths(env_dir, pins)
    var out_dir = join_path(work, String("out"))
    for k in range(len(paths)):
        var file = String("openssl_") + String(k + 1) + String(".mojo")
        var stdout_path = join_path(out_dir, _record_of(file) + String(".stdout"))
        var err = join_path(out_dir, _record_of(file) + String(".stderr"))
        var owner = paths[k][byte = paths[k].rfind(String("/")) + 1 :]
        var expected = (
            String("the system OpenSSL's SSL_CTX_new works with ") + String(owner) + String(" loaded first, RTLD_GLOBAL")
        )
        var got: String
        var ok = False
        try:
            _write(join_path(work, file), openssl_program_text(paths[k], libssl))
            var r = _start(
                runner,
                RunSpec(pixi.copy(), run_program_argv(work, file), work.copy(), ENV_RUN_TIMEOUT_S, stdout_path.copy(), err.copy()),
                env.copy(),
            )
            ok = r.ok() and read_or_empty(stdout_path).find(String(OPENSSL_OK)) >= 0
            if ok:
                got = String("openssl: ") + String(owner) + String(" beside the system OpenSSL: SSL_CTX_new works")
            elif r.signaled:
                got = (
                    String("openssl: ") + String(owner) + String(" beside the system OpenSSL: the program crashed (")
                    + _why(r, err) + String("): an export of it interposes on the system's OpenSSL")
                )
            else:
                got = String("openssl: ") + String(owner) + String(" beside the system OpenSSL: ") + _why(r, err)
        except e:
            got = String("openssl: ") + String(owner) + String(": ") + String(e)
        checks.append(_row(String(CHECK_OPENSSL), expected^, got^, ok))


def run_native_rows[R: ProcessRunner](
    mut runner: R, v: StageValidation, channel_url: String, mojo_pin: String, dir: String, named: List[InstallPin],
    pins: List[InstallPin], programs: List[ReadmeProgram], mut checks: List[ResultValidationCheck],
):
    """The native rows after the README programs (file header): `dir` is
    `<scratch>/<validation>`, whose work/ holds the whole set's environment."""
    var bin = join_path(dir, String(PIXI_LINK_DIR))
    var pixi = join_path(bin, String(PIXI_NAME))
    var work = join_path(dir, String("work"))
    var env = env_child_env(bin, work)
    var env_dir = env_records_dir(work)
    # rows 2 and 3, glibc, DF_SYMBOLIC
    _ = check_native_install(env_dir, pins, checks)
    # row 6: each README whose closure links native files, built
    for i in range(len(programs)):
        ref p = programs[i]
        for k in range(len(pins)):
            if pins[k].is_library and pins[k].import_name == p.package and not pins[k].link.is_empty():
                _built_rows(runner, pixi, work, env, p, checks)
                break
    # row 4, in the whole set
    _load_row(runner, pixi, work, env, pins, String("the whole set"), checks)
    # rows 4 and 5, each native package alone
    var alone = alone_pins(named, pins)
    for i in range(len(alone)):
        _alone_rows(runner, v, channel_url, mojo_pin, dir, pins, alone[i], programs, checks)
    # row 7, beside the system OpenSSL
    if len(shared_paths(env_dir, pins)) > 0:
        _openssl_rows(runner, v, channel_url, mojo_pin, dir, named, pins, checks)
