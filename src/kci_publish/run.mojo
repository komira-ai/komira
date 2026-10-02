# =============================================================================
# src/kci_publish/run.mojo -- reading the registry into a plan, and carrying
#   the plan out (or, with --dry-run, only printing it).
# =============================================================================
#
# `plan_publish` asks the registry about every target (one presence read
# each) and hands the answers to the pure `plan_from_presence`.
#
# `run_publish` executes a plan:
#   * a plan holding any REFUSE uploads nothing: exit 3, or 5 when every
#     refusal is a read that could not be answered;
#   * `dry_run` returns the plan's lines and exit 0. It makes NO call on the
#     registry set: no transport request and no credential request, so no
#     token is resolved or minted and nothing is uploaded;
#   * otherwise the credential is asked for every (surface, host) the
#     uploads need BEFORE the first upload, so a credential refusal (an OIDC
#     environment that is not the required one, or a host the credential was
#     not issued for, included) stops the run with nothing uploaded. Then
#     each UPLOAD entry, in order:
#       - the file is read again and must still have the planned sha256;
#       - CREATED, DUPLICATE_REFUSED (a 409: a file of that name is already
#         there) and UNKNOWN (the answer was lost; the bytes may or may not
#         have landed) are all settled by the SAME bounded read-back poll,
#         because the index lags an upload whoever made it. A 409 is the
#         usual answer on a re-run after a lost answer, while the index
#         still lags;
#       - read back identical: CREATED and UNKNOWN count as uploaded, a 409
#         is SKIPPED;
#       - read back PRESENT_DIFFERENT or NO_COMMON_FIELD fails the run: a
#         different file holds that name;
#       - anything else after the last poll (ABSENT, UNKNOWN, AUTH, RATE) is
#         "cannot tell". After a 409 that is never a definite failure: the
#         server said a file of that name exists, and the index has not yet
#         shown which;
#       - any other upload answer fails the run.
#     The first failure stops the run; later entries are NOT-ATTEMPTED.
#
# EXIT CODES: 0 everything uploaded or skipped; 3 refused before any upload;
# 4 failed after the run began uploading; 5 cannot tell whether a file
# landed (2, a usage error, is the CLI's).
#
# Every line `run_publish` emits is safe to log: registry answers pass
# through kci_pkg_upload's credential-echo redaction, and no line carries a
# token.
#
# Encapsulation: owned values; the registry set is borrowed `mut` for the
# call. No pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from kci_pkg_upload import (
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    SUBSTRATE_PREFIX_DEV_CONDA,
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_UNKNOWN,
    ApprovedNames,
    ContentIdentity,
    PackageFile,
    PkgTransport,
    Presence,
    RegistryCredential,
    RegistrySet,
    presence_kind_name,
)
from kci_pkg_upload.coordinate import repo_host
from kci_release_channel import ChannelDeclaration
from komira_retry import Sleeper

from .plan import (
    ACTION_REFUSE,
    ACTION_SKIP,
    ACTION_UPLOAD,
    PublishPlan,
    PublishTarget,
    action_name,
    plan_from_presence,
)


comptime EXIT_OK: Int = 0
comptime EXIT_USAGE: Int = 2
comptime EXIT_REFUSED: Int = 3
comptime EXIT_FAILED: Int = 4
comptime EXIT_CANNOT_TELL: Int = 5


struct RunOptions(Copyable, Movable, Deinitable):
    """How long a fresh upload's read-back may wait for the index: up to
    `read_back_attempts` reads, `read_back_wait_ms` apart.

    Layout: an Int and an Int64. No pointer field."""

    var read_back_attempts: Int
    var read_back_wait_ms: Int64

    def __init__(out self, read_back_attempts: Int = 6, read_back_wait_ms: Int64 = 10_000):
        self.read_back_attempts = read_back_attempts
        self.read_back_wait_ms = read_back_wait_ms


struct PublishReport(Copyable, Movable, Deinitable):
    """The run's outcome: an exit code and the lines to print, in order.

    Layout: an Int, two counters and an owned list. No pointer field."""

    var exit_code: Int
    var uploaded: Int
    var skipped: Int
    var lines: List[String]

    def __init__(out self):
        self.exit_code = EXIT_OK
        self.uploaded = 0
        self.skipped = 0
        self.lines = List[String]()

    @staticmethod
    def refused(code: Int, var message: String) -> PublishReport:
        """A report for a run refused before any plan line: one or more lines
        of `message`, and `code`."""
        var r = PublishReport()
        r.exit_code = code
        var parts = message.split(String("\n"))
        for i in range(len(parts)):
            r.lines.append(String(parts[i]))
        return r^

    def has_line_containing(self, needle: String) -> Bool:
        for i in range(len(self.lines)):
            if self.lines[i].find(needle) >= 0:
                return True
        return False


def expected_identity(t: PublishTarget) -> ContentIdentity:
    return ContentIdentity.of_sha256_hex(t.sha256_hex.copy())


def plan_publish[T: PkgTransport, C: RegistryCredential](
    mut registry: RegistrySet[T, C],
    channel: ChannelDeclaration,
    targets: List[PublishTarget],
) raises -> PublishPlan:
    """One presence read per target, then `plan_from_presence`."""
    var presences = List[Presence]()
    for i in range(len(targets)):
        presences.append(
            registry.presence(targets[i].coordinate, expected_identity(targets[i]))
        )
    return plan_from_presence(channel, targets, presences)


def render_plan(plan: PublishPlan, dry_run: Bool) -> List[String]:
    """The plan as lines: a header, then one line per artifact."""
    var out = List[String]()
    out.append(
        String("PLAN channel=")
        + plan.channel
        + String(" visibility=")
        + plan.visibility
        + String(" upload=")
        + String(plan.count(ACTION_UPLOAD))
        + String(" skip=")
        + String(plan.count(ACTION_SKIP))
        + String(" refuse=")
        + String(plan.count(ACTION_REFUSE))
        + (String(" (dry run)") if dry_run else String(""))
    )
    for i in range(len(plan.entries)):
        ref e = plan.entries[i]
        var line = (
            action_name(e.action)
            + String(" ")
            + e.target.where()
            + String(" sha256=")
            + e.target.sha256_hex
        )
        if e.reason.byte_length() > 0:
            line += String(" -- ") + e.reason
        out.append(line^)
    return out^


def _surface_of(t: PublishTarget) -> Int:
    if t.coordinate.substrate == SUBSTRATE_PREFIX_DEV_CONDA:
        return SURFACE_PREFIX_DEV
    return SURFACE_PYPI_UPLOAD


def surfaces_needed(plan: PublishPlan) -> List[Int]:
    """The credential surfaces the plan's UPLOAD entries need, each once."""
    var out = List[Int]()
    for i in range(len(plan.entries)):
        ref e = plan.entries[i]
        if e.action != ACTION_UPLOAD:
            continue
        var s = _surface_of(e.target)
        var seen = False
        for j in range(len(out)):
            if out[j] == s:
                seen = True
        if not seen:
            out.append(s)
    return out^


def _ask_credential_first[T: PkgTransport, C: RegistryCredential](
    plan: PublishPlan, mut registry: RegistrySet[T, C]
) raises:
    """Ask the credential for each (surface, host) the UPLOAD entries need,
    each once, so a refusal comes before the first upload."""
    var surfaces = List[Int]()
    var hosts = List[String]()
    for i in range(len(plan.entries)):
        ref e = plan.entries[i]
        if e.action != ACTION_UPLOAD:
            continue
        var s = _surface_of(e.target)
        var h = repo_host(e.target.coordinate.repo)
        var seen = False
        for j in range(len(surfaces)):
            if surfaces[j] == s and hosts[j] == h:
                seen = True
        if seen:
            continue
        _ = registry.credential().authorization(s, h)
        surfaces.append(s)
        hosts.append(h^)


def package_file_of(t: PublishTarget) raises -> PackageFile:
    """The target's bytes (and, for PYTHON, its METADATA text), read now.
    RAISES when a file cannot be read or no longer has the planned sha256."""
    var data = Path(t.file_path).read_bytes()
    var meta = String("")
    if t.metadata_path.byte_length() > 0:
        meta = Path(t.metadata_path).read_text()
    var f = PackageFile(t.coordinate.copy(), data^, meta^)
    if f.identity.sha256_hex != t.sha256_hex:
        raise Error(
            String("'")
            + t.file_path
            + String("' changed since it was planned (sha256 now ")
            + f.identity.sha256_hex
            + String(")")
        )
    return f^


def _describe(p: Presence) -> String:
    var s = presence_kind_name(p.kind) + String(" (HTTP ") + String(p.status) + String(")")
    if p.detail.byte_length() > 0:
        s += String(": ") + p.detail
    return s^


def _read_back_until_identical[T: PkgTransport, C: RegistryCredential, S: Sleeper](
    mut registry: RegistrySet[T, C],
    t: PublishTarget,
    opts: RunOptions,
    mut sleeper: S,
) raises -> Presence:
    """Poll presence until PRESENT_IDENTICAL, a definite mismatch, or the
    last attempt; return the last answer."""
    var attempts = opts.read_back_attempts if opts.read_back_attempts > 0 else 1
    var p = registry.presence(t.coordinate, expected_identity(t))
    var n = 1
    while n < attempts:
        if (
            p.kind == PRESENCE_PRESENT_IDENTICAL
            or p.kind == PRESENCE_PRESENT_DIFFERENT
            or p.kind == PRESENCE_NO_COMMON_FIELD
        ):
            break
        sleeper.sleep_ms(opts.read_back_wait_ms)
        p = registry.presence(t.coordinate, expected_identity(t))
        n += 1
    return p^


def _finish(mut r: PublishReport, plan: PublishPlan, from_index: Int):
    for i in range(from_index, len(plan.entries)):
        ref e = plan.entries[i]
        if e.action == ACTION_UPLOAD:
            r.lines.append(String("NOT-ATTEMPTED ") + e.target.where())
    r.lines.append(
        String("RESULT exit=")
        + String(r.exit_code)
        + String(" uploaded=")
        + String(r.uploaded)
        + String(" skipped=")
        + String(r.skipped)
    )


def _fail(mut r: PublishReport, code: Int, line: String):
    r.lines.append(line)
    r.exit_code = code


def run_publish[T: PkgTransport, C: RegistryCredential, S: Sleeper](
    plan: PublishPlan,
    mut registry: RegistrySet[T, C],
    names: ApprovedNames,
    dry_run: Bool,
    opts: RunOptions,
    mut sleeper: S,
) -> PublishReport:
    """Execute `plan` (see the file header). `sleeper` waits between
    read-back polls. Never raises: every fault is a line and an exit code."""
    var r = PublishReport()
    r.lines = render_plan(plan, dry_run)
    if plan.count(ACTION_REFUSE) > 0:
        r.exit_code = EXIT_REFUSED if plan.has_definite_refusal() else EXIT_CANNOT_TELL
        r.lines.append(
            String("REFUSED before any upload: ")
            + String(plan.count(ACTION_REFUSE))
            + String(" artifact(s) cannot be published as planned")
        )
        _finish(r, plan, len(plan.entries))
        return r^
    if dry_run:
        r.lines.append(String("DRY RUN: nothing was uploaded"))
        _finish(r, plan, len(plan.entries))
        return r^
    try:
        _ask_credential_first(plan, registry)
    except e:
        _fail(r, EXIT_REFUSED, String("REFUSED credential: ") + String(e))
        _finish(r, plan, 0)
        return r^
    for i in range(len(plan.entries)):
        ref e = plan.entries[i]
        ref t = e.target
        if e.action == ACTION_SKIP:
            r.skipped += 1
            r.lines.append(String("SKIPPED ") + t.where() + String(" -- ") + e.reason)
            continue
        var fail_code = EXIT_FAILED if r.uploaded > 0 else EXIT_REFUSED
        try:
            var f = package_file_of(t)
            var o = registry.upload(f, names)
            if (
                o.kind == UPLOAD_CREATED
                or o.kind == UPLOAD_DUPLICATE_REFUSED
                or o.kind == UPLOAD_UNKNOWN
            ):
                var p = _read_back_until_identical(registry, t, opts, sleeper)
                if p.kind == PRESENCE_PRESENT_IDENTICAL:
                    if o.kind == UPLOAD_DUPLICATE_REFUSED:
                        r.skipped += 1
                        r.lines.append(
                            String("SKIPPED ")
                            + t.where()
                            + String(" -- the registry already holds it, identical (HTTP 409)")
                        )
                        continue
                    r.uploaded += 1
                    var line = String("UPLOADED ") + t.where() + String(" sha256=") + t.sha256_hex
                    if o.kind == UPLOAD_UNKNOWN:
                        line += String(" (the upload's answer was lost; read back identical)")
                    r.lines.append(line^)
                    continue
                if o.kind == UPLOAD_CREATED:
                    r.uploaded += 1
                var what = String(" -- uploaded, ")
                if o.kind != UPLOAD_CREATED:
                    what = String(" -- ") + o.detail + String("; ")
                if (
                    p.kind == PRESENCE_PRESENT_DIFFERENT
                    or p.kind == PRESENCE_NO_COMMON_FIELD
                ):
                    var code = EXIT_FAILED if r.uploaded > 0 else EXIT_REFUSED
                    _fail(
                        r,
                        code,
                        String("FAILED ")
                        + t.where()
                        + what
                        + String("but the registry reads back ")
                        + _describe(p),
                    )
                else:
                    _fail(
                        r,
                        EXIT_CANNOT_TELL,
                        String("UNCONFIRMED ")
                        + t.where()
                        + what
                        + String("not read back identical after ")
                        + String(max(opts.read_back_attempts, 1))
                        + String(" read(s): ")
                        + _describe(p),
                    )
                _finish(r, plan, i + 1)
                return r^
            _fail(r, fail_code, String("FAILED ") + t.where() + String(" -- ") + o.detail)
            _finish(r, plan, i + 1)
            return r^
        except err:
            _fail(r, fail_code, String("FAILED ") + t.where() + String(" -- ") + String(err))
            _finish(r, plan, i + 1)
            return r^
    _finish(r, plan, len(plan.entries))
    return r^
