# =============================================================================
# src/kci_validate/readback.mojo -- checks 2 to 4, read back from the
#   container's mount after it exits: what was installed, the installed
#   payload, and the program's count.
# =============================================================================
#
# 2 INSTALL. `out/install.exit` must say 0 (else the install log's tail is
# the finding, and nothing else is read). Then the environment's conda-meta
# records (`<work>/.pixi/envs/default/conda-meta/*.json`, the data `conda
# list --json` reads):
#   * each install name: a record whose `version` and `build` are the
#     release's, whose `url` is under `<channel>/`, and whose `sha256` is the
#     file the build made;
#   * `mojo-compiler`: present, `version` the libraries' mojo_pin, `url`
#     under the compiler channel;
#   * EVERY record's `url` is under one of the declared channels (the step's,
#     the compiler channel, the extra channels; `conda-forge` is
#     https://conda.anaconda.org/conda-forge): the container's network is not
#     restricted, so "only the declared channels" is enforced on what was
#     installed, after the solve.
# 3 PAYLOAD. For each library: the sha256 the script recorded of its
# installed payload (`out/payload.<name>`) equals metadata.json's
# `payload_sha256`.
# 4 PROGRAM. `out/<record>.exit` says 0 and `out/<record>.out` holds the line
# `<stem> validation: N of M checks passed` with N == M > 0 (the program
# states its own number of checks, so a run that stopped early or checked
# nothing is not a pass). <stem> is the program's file name without `.mojo`
# and a leading `smoke_`. <record> is `smoke` for the container's program,
# and `readme_<import name>` for each README program of an ENV validation.
# A failing row quotes the program's `FAILED` lines (`<readme>:<line>:
# FAILED: ...` for a README example).
#
# The ENV runner writes the same records the container script wrote
# (env.mojo), so these checks read both environments.
#
# Each finding is one row in the words of the shell reference this ports
# (tools/build/package/validate_published.sh, checks 2 to 4); a phase that
# passes writes one row saying so. A record that does not parse is a
# finding, never skipped.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir
from std.os.path import isdir

from komira_json import JsonValue, parse_json_value

from kci_api import ResultValidationCheck
from kci_release_machine import StageValidation

from .container import COMPILER_PACKAGE, ENV_DIR, channel_url_of, join_path, payload_record_name
from .request import InstallPin

comptime CHECK_INSTALL: String = "install"
comptime CHECK_PAYLOAD: String = "payload"
comptime CHECK_PROGRAM: String = "program"
comptime COUNT_INFIX: String = " validation: "
comptime COUNT_SUFFIX: String = " checks passed"
comptime SMOKE_RECORD: String = "smoke"
"""The record stem of the container's program run: out/smoke.{exit,out,err}."""
comptime README_FAILED_INFIX: String = ": FAILED: "
"""What a README program prints for a failed example: `<readme>:<line>: FAILED: <error>`."""


def read_or_empty(path: String) -> String:
    try:
        return open(path, "r").read()
    except:
        return String("")


def _lines(text: String) -> List[String]:
    var out = List[String]()
    var parts = text.split(String("\n"))
    for i in range(len(parts)):
        var l = String(parts[i])
        if l.endswith(String("\r")):
            var trimmed = String(l[byte = 0 : l.byte_length() - 1])
            l = trimmed^
        out.append(l^)
    while len(out) > 0 and out[len(out) - 1].byte_length() == 0:
        _ = out.pop()
    return out^


def tail_lines(text: String, n: Int) -> String:
    """The last `n` non-trailing lines of `text`, `' '`-joined."""
    var lines = _lines(text)
    var start = len(lines) - n
    if start < 0:
        start = 0
    var out = String("")
    for i in range(start, len(lines)):
        if out.byte_length() > 0:
            out += String(" ")
        out += lines[i]
    return out^


def program_stem(program: String) -> String:
    """The program's file name without `.mojo` and without a leading
    `smoke_`."""
    var slash = program.rfind(String("/"))
    var base = String(program[byte = slash + 1 :]) if slash >= 0 else program.copy()
    var n = base.byte_length()
    var start = 0
    var end = n
    if base.endswith(String(".mojo")):
        end = n - 5
    if base.startswith(String("smoke_")) and end > 6:
        start = 6
    return String(base[byte=start:end])


def _str(doc: JsonValue, key: String) -> String:
    try:
        if doc.has(key):
            var v = doc.get(key)
            if v.is_string():
                return v.as_string()
    except:
        pass
    return String("")


struct _Rec(Copyable, Movable):
    """One conda-meta record, as read. Layout: owned Strings only."""

    var file: String
    var name: String
    var version: String
    var build: String
    var sha256: String
    var url: String

    def __init__(out self, var file: String, doc: JsonValue):
        self.file = file^
        self.name = _str(doc, String("name"))
        self.version = _str(doc, String("version"))
        self.build = _str(doc, String("build"))
        self.sha256 = _str(doc, String("sha256"))
        self.url = _str(doc, String("url"))


def _row(var check: String, var expected: String, var got: String, ok: Bool) -> ResultValidationCheck:
    return ResultValidationCheck(check^, expected^, got^, ok)


def install_exited_zero(out_dir: String, mut checks: List[ResultValidationCheck]) -> Bool:
    """Check 2's first half: the install's recorded exit status."""
    var code = String(read_or_empty(join_path(out_dir, String("install.exit"))).strip())
    if code == String("0"):
        return True
    var log = tail_lines(read_or_empty(join_path(out_dir, String("install.log"))), 5)
    var got: String
    if code.byte_length() == 0:
        got = String("install: the container recorded no exit status of pixi install: ") + log
    else:
        got = String("install: pixi could not resolve the pinned packages from the channels: ") + log
    checks.append(_row(String(CHECK_INSTALL), String("pixi install exits 0"), got^, False))
    return False


def _under(url: String, base: String) -> Bool:
    return url.startswith(base + String("/"))


def check_installed(
    work_dir: String,
    validation: StageValidation,
    channel_url: String,
    pins: List[InstallPin],
    mojo_pin: String,
    mut checks: List[ResultValidationCheck],
) -> Bool:
    """Check 2's second half (file header): the records. Appends one row
    per finding, or one passing row. True when there is no finding."""
    var meta_dir = join_path(join_path(work_dir, String(ENV_DIR)), String("conda-meta"))
    var recs = List[_Rec]()
    var before = len(checks)
    var expected = String("the pinned packages, from their channels, with the release's bytes")
    try:
        if not isdir(meta_dir):
            raise Error(String("not a directory"))
        var raw = listdir(meta_dir)
        for i in range(len(raw)):
            var f = String(raw[i])
            if not f.endswith(String(".json")):
                continue
            try:
                var doc = parse_json_value(open(join_path(meta_dir, f), "r").read())
                if not doc.is_object():
                    raise Error(String("not a JSON object"))
                recs.append(_Rec(f.copy(), doc))
            except e:
                checks.append(
                    _row(String(CHECK_INSTALL), expected.copy(), String("install: conda-meta/") + f + String(" is not a package record: ") + String(e), False)
                )
    except e:
        checks.append(
            _row(String(CHECK_INSTALL), expected.copy(), String("install: the environment cannot be read (") + meta_dir + String(": ") + String(e) + String(")"), False)
        )
        return False
    for p in range(len(pins)):
        ref pin = pins[p]
        var at = -1
        for r in range(len(recs)):
            if recs[r].name == pin.name:
                at = r
        if at < 0:
            checks.append(_row(String(CHECK_INSTALL), expected.copy(), String("install: the environment holds no record of ") + pin.name, False))
            continue
        ref rec = recs[at]
        if rec.version != pin.version or rec.build != pin.build:
            checks.append(
                _row(
                    String(CHECK_INSTALL), expected.copy(),
                    String("install: installed ") + pin.name + String(" ") + rec.version + String(" ") + rec.build
                    + String(", expected ") + pin.version + String(" ") + pin.build,
                    False,
                )
            )
        if not _under(rec.url, channel_url):
            checks.append(
                _row(
                    String(CHECK_INSTALL), expected.copy(),
                    String("install: ") + pin.name + String(" came from '") + rec.url + String("', not from ") + channel_url,
                    False,
                )
            )
        if rec.sha256 != pin.sha256:
            var s = rec.sha256.copy() if rec.sha256.byte_length() > 0 else String("none")
            checks.append(
                _row(
                    String(CHECK_INSTALL), expected.copy(),
                    String("install: the installed package's sha256 is '") + s + String("', the build made ") + pin.sha256,
                    False,
                )
            )
    var compiler = -1
    for r in range(len(recs)):
        if recs[r].name == String(COMPILER_PACKAGE):
            compiler = r
    if compiler < 0:
        checks.append(_row(String(CHECK_INSTALL), expected.copy(), String("install: no mojo-compiler in the environment"), False))
    else:
        ref c = recs[compiler]
        if c.version != mojo_pin:
            checks.append(
                _row(
                    String(CHECK_INSTALL), expected.copy(),
                    String("install: installed mojo-compiler ") + c.version + String(", the libraries were built with ") + mojo_pin,
                    False,
                )
            )
        if not _under(c.url, validation.compiler_channel):
            checks.append(
                _row(
                    String(CHECK_INSTALL), expected.copy(),
                    String("install: mojo-compiler came from '") + c.url + String("', not from ") + validation.compiler_channel,
                    False,
                )
            )
    var declared = List[String]()
    declared.append(channel_url.copy())
    declared.append(validation.compiler_channel.copy())
    for i in range(len(validation.extra_channels)):
        declared.append(channel_url_of(validation.extra_channels[i]))
    for r in range(len(recs)):
        var ok = False
        for d in range(len(declared)):
            if _under(recs[r].url, declared[d]):
                ok = True
        if not ok:
            checks.append(
                _row(
                    String(CHECK_INSTALL), expected.copy(),
                    String("install: ") + recs[r].name + String(" came from '") + recs[r].url
                    + String("', which is none of the declared channels"),
                    False,
                )
            )
    if len(checks) > before:
        return False
    var names = String("")
    for p in range(len(pins)):
        if p > 0:
            names += String(", ")
        names += pins[p].name + String(" ") + pins[p].version + String(" ") + pins[p].build
    checks.append(
        _row(
            String(CHECK_INSTALL), expected^,
            String("install: fresh pixi project resolved ") + names + String(" from ") + channel_url
            + String(" and mojo-compiler ") + recs[compiler].version + String(" from ") + validation.compiler_channel,
            True,
        )
    )
    return True


def check_payloads(out_dir: String, pins: List[InstallPin], mut checks: List[ResultValidationCheck]) -> Bool:
    """Check 3 (file header): one row per library."""
    var all_ok = True
    for p in range(len(pins)):
        ref pin = pins[p]
        if not pin.is_library:
            continue
        var text = read_or_empty(join_path(out_dir, payload_record_name(pin)))
        var got = String(text[byte = 0 : 64]) if text.byte_length() >= 64 else String("")
        var expected = String("the installed ") + pin.payload_path + String(" has sha256 ") + pin.payload_sha256
        if got == pin.payload_sha256:
            checks.append(
                _row(
                    String(CHECK_PAYLOAD), expected^,
                    String("payload: ") + pin.payload_path + String(" is byte-identical to the build's (")
                    + String(got[byte = 0 : 16]) + String("...)"),
                    True,
                )
            )
        else:
            checks.append(
                _row(
                    String(CHECK_PAYLOAD), expected^,
                    String("payload: the installed ") + pin.payload_path
                    + String(" is missing or differs from the one in the package the build made"),
                    False,
                )
            )
            all_ok = False
    return all_ok


def _parse_count(line: String, prefix: String) -> Tuple[Int, Int]:
    """`<prefix>N of M checks passed` -> (N, M); (-1, -1) otherwise."""
    if not line.startswith(prefix) or not line.endswith(String(COUNT_SUFFIX)):
        return (-1, -1)
    var mid = String(line[byte = prefix.byte_length() : line.byte_length() - String(COUNT_SUFFIX).byte_length()])
    var of = mid.find(String(" of "))
    if of <= 0:
        return (-1, -1)
    var a = String(mid[byte=0:of])
    var b = String(mid[byte = of + 4 :])
    for word in [a.copy(), b.copy()]:
        var bytes = word.as_bytes()
        if len(bytes) == 0 or len(bytes) > 9:
            return (-1, -1)
        for i in range(len(bytes)):
            if Int(bytes[i]) < 48 or Int(bytes[i]) > 57:
                return (-1, -1)
    try:
        return (Int(a), Int(b))
    except:
        return (-1, -1)


def check_program(
    out_dir: String, program: String, mut checks: List[ResultValidationCheck], record: String = String(SMOKE_RECORD)
) -> Bool:
    """Check 4 (file header): one row. `record` names the files the run left
    in `out_dir`: `<record>.exit`, `<record>.out`, `<record>.err`."""
    var stem = program_stem(program)
    var prefix = stem + String(COUNT_INFIX)
    var expected = String("mojo run exits 0 and prints '") + prefix + String("N of N checks passed', N > 0")
    var code = String(read_or_empty(join_path(out_dir, record + String(".exit"))).strip())
    var out = _lines(read_or_empty(join_path(out_dir, record + String(".out"))))
    if code != String("0"):
        var said = String("")
        var shown = 0
        for i in range(len(out)):
            var failed = out[i].startswith(String("FAILED")) or out[i].find(String(README_FAILED_INFIX)) > 0
            if shown < 5 and (failed or out[i].startswith(prefix)):
                said += out[i] + String(";")
                shown += 1
        var why = String("mojo run failed: ")
        if code.byte_length() == 0:
            why = String("no exit status of mojo run was recorded: ")
        checks.append(
            _row(
                String(CHECK_PROGRAM), expected^,
                String("program: ") + why + said + String(" ") + tail_lines(read_or_empty(join_path(out_dir, record + String(".err"))), 2),
                False,
            )
        )
        return False
    for i in range(len(out)):
        var c = _parse_count(out[i], prefix)
        if c[0] >= 0 and c[0] == c[1] and c[0] > 0:
            checks.append(
                _row(
                    String(CHECK_PROGRAM), expected^,
                    String("program: mojo run of an import of ") + stem + String(" ran ") + String(c[0]) + String(" checks, all passed"),
                    True,
                )
            )
            return True
    var last = out[len(out) - 1].copy() if len(out) > 0 else String("")
    checks.append(
        _row(String(CHECK_PROGRAM), expected^, String("program: it exited 0 but printed no complete count (got: '") + last + String("')"), False)
    )
    return False
