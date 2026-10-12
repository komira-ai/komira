# =============================================================================
# src/kci_validate/native_install.mojo -- the native install checks over an
#   installed environment: each library's `lib_files` rows against the files,
#   the glibc floor, each `.so`'s NEEDED and DF_SYMBOLIC, and the loader's
#   record of where a program's komira objects came from.
# =============================================================================
#
# docs/design/native_packaging.md, slice 9: a library shipping native code
# carries metadata.json `lib_files` rows `{kind, path, sha256}` (written by
# tools/build/package/pack/conda_lib.zig; read by kci_release_set's
# `LibFile`) and the run requirement `__glibc >=<floor>`. After an install,
# with LD_LIBRARY_PATH unset, `check_native_install(env_dir, pins, checks)`
# adds one row per check below for every library pin with `lib_files` (a pin
# without them adds no row: a package with no native file has nothing to
# check), each listing every finding:
#
#   lib_files  install check 2. The rows agree with each other (at most one
#              `shared`, `lib/lib<x>.so.<n>`; a `link` exactly when there is
#              a shared row, at its unversioned name `lib/lib<x>.so`, with its
#              sha256; a `static` named `lib/lib<x>.a`). Each row's file under
#              <env>: a `shared` row a regular file of mode 755, a `static`
#              row a regular file of mode 644, each with the row's sha256; a
#              `link` row a symbolic link that resolves (a dangling link is a
#              finding) to the shared row's file, the bytes it resolves to
#              having the row's sha256. Nothing extra: every `lib/<file>`
#              (directly in lib/; the payload is lib/mojo/<import>.mojoc)
#              that the package's conda-meta record (`files`) lists is a row,
#              every row is listed there, and no `lib/libkomira_*` file in
#              the environment is unlisted by every installed record (a file
#              no package owns);
#   glibc      the pin's run requirements hold kci_release_set's
#              `glibc_requirement_refusals`: `__glibc >=2.34` exactly once,
#              any other value refused;
#   needed     install check 3. Each NEEDED of each `shared` row resolves
#              inside the environment the way the loader would with
#              LD_LIBRARY_PATH unset: a glibc soname (`glibc_sonames`, the
#              host's, which `__glibc` pins) is the host's; any other is
#              found only through the `.so`'s own DT_RUNPATH `$ORIGIN`, so it
#              must be `<env>/lib/<name>` and resolve under <env>. A RUNPATH
#              or RPATH entry other than `$ORIGIN` would search outside the
#              environment and is a finding; NEEDED
#              `libkomira_log_holder_jit.so.1` (the JIT-only holder) is one;
#   symbolic   the build's check 6 on the installed bytes: DT_FLAGS carries
#              DF_SYMBOLIC (or a DT_SYMBOLIC tag), what `-Bsymbolic` leaves.
#
# Install check 5, the loaded-from row: `loaded_from_findings(trace,
# env_dir)` reads a glibc loader record (`LD_DEBUG=libs`: one `calling init:
# <path>` line per object mapped) and refuses every komira object
# (`libkomira_*`) and every system codec of kci_release_set's
# `system_libs()` loaded from outside `<env>/lib`, and a record with no
# `calling init:` line at all (LD_DEBUG not honoured: a vacuous pass).
# `run_loaded_from` runs a program through the injected `ProcessRunner` with
# `LD_DEBUG=libs` and `LD_DEBUG_OUTPUT` added to its cleared environment and
# any `LD_LIBRARY_PATH` entry of the caller's dropped from it, then reads the
# record it wrote.
#
# `loader_env` and `loader_record` are run_loaded_from's two halves, for a
# caller that runs the program itself.
#
# Wired (slice 11 of docs/design/native_packaging.md): a CONDA_INSTALL_ENV
# validation that installs a native library pin (native_rows.mojo) runs
# these, which is what beta's `beta_validate` job runs.
#
# Pure checks over files; the one process is the runner's. Encapsulation:
# owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, lstat, stat
from std.os.path import exists, islink, realpath

from komira_json import JsonValue, parse_json_value

from kci_api import ResultValidationCheck
from kci_build.runner import ProcessRunner, RunSpec
from kci_release_set.conda_metadata import LIB_DIR, LIB_KIND_LINK, LIB_KIND_SHARED, LIB_KIND_STATIC, LibFile
from kci_release_set.glibc_floor import glibc_requirement, glibc_requirement_refusals
from kci_release_set.member import file_sha256_hex
from kci_release_set.system_libs import system_libs

from .container import join_path
from .elf_dynamic import read_dynamic
from .request import InstallPin

comptime CHECK_LIB_FILES: String = "lib_files"
comptime CHECK_GLIBC: String = "glibc"
comptime CHECK_NEEDED: String = "needed"
comptime CHECK_SYMBOLIC: String = "symbolic"
comptime CHECK_LOADED_FROM: String = "loaded_from"
comptime JIT_HOLDER_SONAME: String = "libkomira_log_holder_jit.so.1"
"""The JIT-only holder: no installed `.so` may need it (design, option A)."""
comptime ORIGIN: String = "$ORIGIN"
comptime CALLING_INIT: String = "calling init: "
comptime S_IFMT: Int = 0o170000
comptime S_IFREG: Int = 0o100000


def glibc_sonames() -> List[String]:
    """The sonames glibc ships, which the host provides (pinned by
    `__glibc`), on the platforms the packer writes (x86-64 and aarch64)."""
    var out = List[String]()
    out.append(String("libc.so.6"))
    out.append(String("libm.so.6"))
    out.append(String("libpthread.so.0"))
    out.append(String("libdl.so.2"))
    out.append(String("librt.so.1"))
    out.append(String("libresolv.so.2"))
    out.append(String("libutil.so.1"))
    out.append(String("ld-linux-x86-64.so.2"))
    out.append(String("ld-linux-aarch64.so.1"))
    return out^


def _has(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _base(path: String) -> String:
    var slash = path.rfind(String("/"))
    return String(path[byte = slash + 1 :]) if slash >= 0 else path.copy()


def _is_digits(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if Int(b[i]) < 48 or Int(b[i]) > 57:
            return False
    return True


def link_name_of(shared_path: String) -> String:
    """`lib/lib<x>.so` for `lib/lib<x>.so.<digits>`; EMPTY for another shape."""
    var at = shared_path.rfind(String(".so."))
    if at < 0 or not _is_digits(String(shared_path[byte = at + 4 :])):
        return String("")
    return String(shared_path[byte = 0 : at + 3])


def lib_rows_findings(rows: List[LibFile]) -> List[String]:
    """How `rows` disagree with each other (file header, `lib_files`)."""
    var out = List[String]()
    var shared = List[Int]()
    var links = List[Int]()
    for i in range(len(rows)):
        ref r = rows[i]
        var name = _base(r.path)
        if r.kind == LIB_KIND_SHARED:
            shared.append(i)
            if not name.startswith(String("lib")) or link_name_of(r.path).byte_length() == 0:
                out.append(String("row ") + r.path + String(" is shared and not lib/lib<name>.so.<number>"))
        elif r.kind == LIB_KIND_LINK:
            links.append(i)
        elif r.kind == LIB_KIND_STATIC:
            if not name.startswith(String("lib")) or not name.endswith(String(".a")) or name.byte_length() <= 5:
                out.append(String("row ") + r.path + String(" is static and not lib/lib<name>.a"))
    if len(shared) > 1:
        out.append(String(len(shared)) + String(" shared rows; a library ships one shared library"))
    if len(shared) == 1:
        ref s = rows[shared[0]]
        var want = link_name_of(s.path)
        if len(links) != 1:
            out.append(
                String("the shared row ") + s.path + String(" has ") + String(len(links))
                + String(" link rows; it must have one, ") + want
            )
        else:
            ref l = rows[links[0]]
            if l.path != want:
                out.append(String("the link row is ") + l.path + String(", not ") + want + String(", the link name of ") + s.path)
            if l.sha256_hex != s.sha256_hex:
                out.append(
                    String("the link row ") + l.path + String(" records sha256 ") + l.sha256_hex
                    + String(", not its target's ") + s.sha256_hex
                )
    elif len(links) > 0:
        out.append(String("a link row (") + rows[links[0]].path + String(") with no shared row to link to"))
    return out^


def _mode(path: String) raises -> Int:
    return Int(stat(path).st_mode)


def _is_regular_not_link(path: String) raises -> Bool:
    return (Int(lstat(path).st_mode) & S_IFMT) == S_IFREG


def _file_finding(env_dir: String, r: LibFile, want_mode: Int) -> String:
    """"" when the regular file of row `r` is as recorded; the finding."""
    var full = join_path(env_dir, r.path)
    try:
        if islink(full):
            return r.path + String(" is a symbolic link; its row is ") + r.kind + String(", a regular file")
        if not exists(full):
            return r.path + String(" is missing: its lib_files row lists it and the environment has no such file")
        if not _is_regular_not_link(full):
            return r.path + String(" is not a regular file")
        var mode = _mode(full) & 0o7777
        if mode != want_mode:
            return (
                r.path + String(" has mode ") + _octal(mode) + String(", must be ") + _octal(want_mode)
                + String(" (a ") + r.kind + String(" row)")
            )
        var sha = file_sha256_hex(full)
        if sha != r.sha256_hex:
            return r.path + String(" has sha256 ") + sha + String(", its lib_files row records ") + r.sha256_hex
    except e:
        return r.path + String(": ") + String(e)
    return String("")


def _octal(v: Int) -> String:
    if v == 0:
        return String("0")
    var out = String("")
    var x = v
    while x > 0:
        out = String(x % 8) + out
        x //= 8
    return out^


def _link_finding(env_dir: String, r: LibFile, rows: List[LibFile]) -> String:
    var full = join_path(env_dir, r.path)
    try:
        if not islink(full):
            if exists(full):
                return r.path + String(" is not a symbolic link; its row is a link")
            return r.path + String(" is missing: its lib_files row lists it and the environment has no such link")
        if not exists(full):
            return r.path + String(" is a dangling symbolic link: it resolves to no file")
        var target = String("")
        for i in range(len(rows)):
            if rows[i].kind == LIB_KIND_SHARED:
                target = join_path(env_dir, rows[i].path)
        if target.byte_length() == 0 or realpath(full) != realpath(target):
            return (
                r.path + String(" resolves to ") + realpath(full) + String(", not the shared row's file ")
                + (target if target.byte_length() > 0 else String("(none)"))
            )
        var sha = file_sha256_hex(full)
        if sha != r.sha256_hex:
            return r.path + String(" resolves to bytes of sha256 ") + sha + String(", its lib_files row records ") + r.sha256_hex
    except e:
        return r.path + String(": ") + String(e)
    return String("")


def record_files(env_dir: String, pin: InstallPin) raises -> List[String]:
    """The `files` of `pin`'s conda-meta record in `env_dir`. RAISES when
    the record is absent, unreadable or has no `files` list."""
    var path = join_path(env_dir, String("conda-meta/") + pin.name + String("-") + pin.version + String("-") + pin.build + String(".json"))
    return _files_of(path)


def _files_of(path: String) raises -> List[String]:
    var doc = parse_json_value(open(path, "r").read())
    if not doc.is_object() or not doc.has(String("files")):
        raise Error(String("conda-meta record ") + path + String(" has no files list"))
    var files = doc.get(String("files"))
    var out = List[String]()
    for i in range(files.array_len()):
        out.append(files.element_at(i).as_string())
    return out^


def _all_recorded_files(env_dir: String) -> List[String]:
    """Every `files` entry of every conda-meta record in `env_dir`."""
    var out = List[String]()
    try:
        var dir = join_path(env_dir, String("conda-meta"))
        var names = listdir(dir)
        for i in range(len(names)):
            if not String(names[i]).endswith(String(".json")):
                continue
            try:
                out.extend(_files_of(join_path(dir, String(names[i]))))
            except:
                pass
    except:
        pass
    return out^


def _in_lib_dir(path: String) -> Bool:
    """`lib/<file name>` itself: the payload's lib/mojo/<import>.mojoc is
    not a native file."""
    return path.startswith(LIB_DIR) and String(path[byte = LIB_DIR.byte_length() :]).find(String("/")) < 0


def lib_files_findings(env_dir: String, pin: InstallPin) -> List[String]:
    """Install check 2 for one library pin (file header, `lib_files`)."""
    var out = lib_rows_findings(pin.lib_files)
    var paths = List[String]()
    for i in range(len(pin.lib_files)):
        ref r = pin.lib_files[i]
        paths.append(r.path.copy())
        var f: String
        if r.kind == LIB_KIND_LINK:
            f = _link_finding(env_dir, r, pin.lib_files)
        else:
            f = _file_finding(env_dir, r, 0o755 if r.kind == LIB_KIND_SHARED else 0o644)
        if f.byte_length() > 0:
            out.append(f^)
    # nothing extra: the package's own record, then the environment's lib/
    try:
        var files = record_files(env_dir, pin)
        for i in range(len(files)):
            if _in_lib_dir(files[i]) and not _has(paths, files[i]):
                out.append(files[i] + String(" is installed by ") + pin.name + String(" and is not one of its lib_files rows"))
        for i in range(len(paths)):
            if not _has(files, paths[i]):
                out.append(paths[i] + String(" is a lib_files row the installed record of ") + pin.name + String(" does not list"))
    except e:
        out.append(String(e))
    var owned = _all_recorded_files(env_dir)
    try:
        var lib = join_path(env_dir, String("lib"))
        var names = listdir(lib)
        for i in range(len(names)):
            var n = String(names[i])
            var rel = String(LIB_DIR) + n
            if n.startswith(String("libkomira_")) and not _has(owned, rel) and not _has(paths, rel):
                out.append(rel + String(" is in the environment and no installed package lists it"))
    except:
        pass
    return out^


def needed_findings(env_dir: String, pin: InstallPin) -> List[String]:
    """Install check 3 for one library pin (file header, `needed`)."""
    var out = List[String]()
    var glibc = glibc_sonames()
    var env_real = String("")
    try:
        env_real = realpath(env_dir)
    except e:
        out.append(String("the environment ") + env_dir + String(": ") + String(e))
        return out^
    for i in range(len(pin.lib_files)):
        ref r = pin.lib_files[i]
        if r.kind != LIB_KIND_SHARED:
            continue
        var full = join_path(env_dir, r.path)
        try:
            var d = read_dynamic(open(full, "r").read_bytes(), r.path)
            for k in range(len(d.runpath)):
                if d.runpath[k] != ORIGIN:
                    out.append(r.path + String(" has DT_RUNPATH entry '") + d.runpath[k] + String("', which searches outside the environment"))
            for k in range(len(d.rpath)):
                if d.rpath[k] != ORIGIN:
                    out.append(r.path + String(" has DT_RPATH entry '") + d.rpath[k] + String("', which searches outside the environment"))
            var has_origin = _has(d.runpath, String(ORIGIN)) or _has(d.rpath, String(ORIGIN))
            for k in range(len(d.needed)):
                ref n = d.needed[k]
                if n == JIT_HOLDER_SONAME:
                    out.append(r.path + String(" has NEEDED ") + n + String(", the JIT-only holder no installed .so may need"))
                    continue
                if _has(glibc, n):
                    continue
                var cand = join_path(join_path(env_dir, String("lib")), n)
                if not has_origin:
                    out.append(
                        r.path + String(" has NEEDED ") + n + String(" and no DT_RUNPATH $ORIGIN: with LD_LIBRARY_PATH")
                        + String(" unset the loader would search only the system's directories, outside the environment")
                    )
                elif not exists(cand):
                    out.append(
                        r.path + String(" has NEEDED ") + n + String(", which is not in the environment's lib/: it")
                        + String(" would resolve outside the environment, or not at all")
                    )
                elif not realpath(cand).startswith(env_real + String("/")):
                    out.append(
                        r.path + String(" has NEEDED ") + n + String(", whose lib/ entry resolves to ") + realpath(cand)
                        + String(", outside the environment")
                    )
        except e:
            out.append(String(e))
    return out^


def symbolic_findings(env_dir: String, pin: InstallPin) -> List[String]:
    """The build's check 6 on the installed bytes (file header, `symbolic`)."""
    var out = List[String]()
    for i in range(len(pin.lib_files)):
        ref r = pin.lib_files[i]
        if r.kind != LIB_KIND_SHARED:
            continue
        try:
            var d = read_dynamic(open(join_path(env_dir, r.path), "r").read_bytes(), r.path)
            if not d.has_df_symbolic():
                out.append(r.path + String(" has no DF_SYMBOLIC in DT_FLAGS: it was linked without -Bsymbolic"))
        except e:
            out.append(String(e))
    return out^


def _row(check: String, var expected: String, findings: List[String], ok_text: String) -> ResultValidationCheck:
    var ok = len(findings) == 0
    var got = check + String(": ")
    if ok:
        got += ok_text
    else:
        got += String("; ").join(findings)
    return ResultValidationCheck(check.copy(), expected^, got^, ok)


def check_native_install(env_dir: String, pins: List[InstallPin], mut checks: List[ResultValidationCheck]) -> Bool:
    """The native install checks of every library pin with `lib_files` in
    the installed environment `env_dir` (file header): one row per check per
    such pin. True when every row passed (and when no pin ships native
    files)."""
    var all_ok = True
    for i in range(len(pins)):
        ref pin = pins[i]
        if not pin.is_library or not pin.has_lib_files:
            continue
        var who = pin.name + String(": ")
        var rows = List[List[String]]()
        rows.append(lib_files_findings(env_dir, pin))
        rows.append(glibc_requirement_refusals(pin.depends, pin.has_lib_files, pin.subdir))
        rows.append(needed_findings(env_dir, pin))
        rows.append(symbolic_findings(env_dir, pin))
        var names = List[String]()
        names.append(String(CHECK_LIB_FILES))
        names.append(String(CHECK_GLIBC))
        names.append(String(CHECK_NEEDED))
        names.append(String(CHECK_SYMBOLIC))
        var expected: List[String] = [
            String("every lib_files row of ") + pin.name + String(" installed as recorded (mode, sha256, link), nothing extra"),
            String("requires exactly ") + glibc_requirement(pin.subdir),
            String("every NEEDED of each shared row of ") + pin.name + String(" resolves inside the environment"),
            String("each shared row of ") + pin.name + String(" carries DF_SYMBOLIC"),
        ]
        for k in range(len(rows)):
            var prefixed = List[String]()
            for j in range(len(rows[k])):
                prefixed.append(who + rows[k][j])
            if len(prefixed) > 0:
                all_ok = False
            checks.append(_row(names[k], expected[k].copy(), prefixed, pin.name + String(" ok")))
    return all_ok


def loaded_from_findings(trace: String, env_dir: String) -> List[String]:
    """Install check 5 over a loader record (file header)."""
    var out = List[String]()
    var codecs = List[String]()
    var rows = system_libs()
    for i in range(len(rows)):
        codecs.append(rows[i].soname.copy())
    var lib = join_path(env_dir, String("lib")) + String("/")
    var lib_real = String("")
    try:
        lib_real = realpath(join_path(env_dir, String("lib"))) + String("/")
    except:
        lib_real = lib.copy()
    var inits = 0
    var lines = trace.split(String("\n"))
    for i in range(len(lines)):
        var line = String(lines[i])
        var at = line.find(String(CALLING_INIT))
        if at < 0:
            continue
        inits += 1
        var path = String(line[byte = at + CALLING_INIT.byte_length() :])
        var name = _base(path)
        if not name.startswith(String("libkomira_")) and not _has(codecs, name):
            continue
        if not path.startswith(lib) and not path.startswith(lib_real):
            out.append(name + String(" was loaded from ") + path + String(", not from ") + lib)
    if inits == 0:
        out.append(String("the loader's record holds no 'calling init:' line: LD_DEBUG=libs was not honoured, so it shows nothing"))
    return out^


def run_loaded_from[R: ProcessRunner](
    mut runner: R, var spec: RunSpec, env: List[String], record_prefix: String, env_dir: String
) raises -> List[String]:
    """Run `spec` with `env`, less any `LD_LIBRARY_PATH=` entry (the check
    runs with it unset: a search path would load objects from wherever it
    names), plus `LD_DEBUG=libs` and `LD_DEBUG_OUTPUT=<record_prefix>` (the
    loader writes `<record_prefix>.<pid>`), then the
    findings of every record it wrote (file header). RAISES when the run
    cannot start or fails: a program that did not run says nothing about
    where it loaded from."""
    spec.set_env(loader_env(env, record_prefix))
    var r = runner.run(spec)
    if not r.ok():
        raise Error(String("the program ") + spec.command_line() + String(" did not pass: ") + r.describe())
    return loaded_from_findings(loader_record(record_prefix), env_dir)


def loader_env(env: List[String], record_prefix: String) -> List[String]:
    """`env` less any `LD_LIBRARY_PATH=` entry, plus `LD_DEBUG=libs` and
    `LD_DEBUG_OUTPUT=<record_prefix>` (run_loaded_from)."""
    var e = List[String]()
    for i in range(len(env)):
        if not env[i].startswith(String("LD_LIBRARY_PATH=")):
            e.append(env[i].copy())
    e.append(String("LD_DEBUG=libs"))
    e.append(String("LD_DEBUG_OUTPUT=") + record_prefix)
    return e^


def loader_record(record_prefix: String) raises -> String:
    """Every record the loader wrote at `<record_prefix>.<pid>`, one after
    the other ("" when it wrote none). RAISES when the directory cannot be
    read."""
    var slash = record_prefix.rfind(String("/"))
    var dir = String(record_prefix[byte=0:slash]) if slash > 0 else String(".")
    var stem = _base(record_prefix) + String(".")
    var trace = String("")
    var names = listdir(dir)
    for i in range(len(names)):
        if String(names[i]).startswith(stem):
            trace += open(join_path(dir, String(names[i])), "r").read()
    return trace^
