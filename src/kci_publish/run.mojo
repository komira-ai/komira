# =============================================================================
# src/kci_publish/run.mojo -- `run_publish`: contract steps 1 to 6 over a set
#   that step 0 already verified, and the exit code (`report.mojo`'s table).
# =============================================================================
#
#   1. read the channel (`channel_state.mojo`): every file by download, every
#      listed subdir's names; `plan_from_state` decides: 7, 5, 8 or 6 stop
#      here with NO write request;
#   --dry-run stops here too, printing what steps 2 to 4 would do: no write
#      request, and the channel's credential is never asked for a write
#      value (no OIDC exchange);
#   2. the write credential is resolved ONCE (`PublishCredential.arm`), then
#      each member still absent is uploaded (`upload.mojo`); the first member
#      that does not end present-same stops the run;
#   3. EVERY member is downloaded back and compared;
#   4. only then the metapackage, uploaded (or found present-same) and read
#      back;
#   5. report-only: is each file in its subdir's repodata yet (`index.mojo`);
#   6. the report (`report.mojo`).
#
# ⚠ NOT CONCURRENT, DELIBERATELY (a stated deviation from the design, which
# asks for up to N workers on komira_async, each with its own registry set).
# komira_async's fork-join (`parallel_fork_join`) runs a `ChunkWork` whose
# `process` takes an immutable `self` and recovers its typed input and output
# by bitcast, and every `HttpPkgTransport` exchange builds its own
# `BlockingRuntime`; running those inside the dispatcher's worker threads is
# unmeasured. A publish uploads a handful of files, so the members go one
# after another on the calling thread, which is the design's
# `--concurrency 1` path, and there is no `--concurrency` flag that would
# claim more. Every per-file rule (settle, bounded retry, read-back barrier,
# metapackage last) is independent of the thread count.
#
# Encapsulation: owned values; the registry set and the credential source are
# borrowed `mut`. No pointer, no wildcard origin.
# =============================================================================

from komira_retry import Sleeper

from kci_pkg_upload import (
    SURFACE_PREFIX_DEV,
    PkgTransport,
    RegistryCredential,
    RegistrySet,
)
from kci_pkg_upload.coordinate import repo_host

from .channel_state import read_channel, read_file_state
from .index import is_indexed
from .plan import (
    STATE_ABSENT,
    STATE_DIFFERENT,
    STATE_SAME,
    VERDICT_ALREADY_PUBLISHED,
    VERDICT_CANNOT_TELL,
    VERDICT_PROCEED,
    VERDICT_STOP_DIFFERENT,
    VERDICT_STOP_NEW_NAME,
    PublishTarget,
    approved_names_for,
    plan_from_state,
    state_name,
)
from .report import (
    EXIT_ALREADY_PUBLISHED,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_PARTIAL,
    EXIT_PUBLISHED,
    EXIT_READ_BACK_MISMATCH,
    EXIT_STOP_DIFFERENT_BYTES,
    EXIT_STOP_NEW_NAME,
    FileRow,
    PublishReport,
)
from .upload import (
    FILE_CANNOT_TELL,
    FILE_DONE,
    FILE_FAILED,
    FILE_STILL_ABSENT,
    FILE_STOP_DIFFERENT,
    FileOutcome,
    PublishCredential,
    RunOptions,
    upload_file,
    read_back_all,
)


def _exit_of_verdict(verdict: Int) -> Int:
    if verdict == VERDICT_STOP_DIFFERENT:
        return EXIT_STOP_DIFFERENT_BYTES
    if verdict == VERDICT_CANNOT_TELL:
        return EXIT_CANNOT_TELL
    if verdict == VERDICT_STOP_NEW_NAME:
        return EXIT_STOP_NEW_NAME
    if verdict == VERDICT_ALREADY_PUBLISHED:
        return EXIT_ALREADY_PUBLISHED
    return EXIT_PUBLISHED


def _exit_of_file(result: Int) -> Int:
    if result == FILE_STOP_DIFFERENT:
        return EXIT_STOP_DIFFERENT_BYTES
    if result == FILE_FAILED:
        return EXIT_FAILED
    if result == FILE_STILL_ABSENT:
        return EXIT_PARTIAL
    if result == FILE_CANNOT_TELL:
        return EXIT_CANNOT_TELL
    return EXIT_PUBLISHED


def _read_back_rank(code: Int) -> Int:
    """Step 3's precedence: a mismatch over a missing member over an
    unreadable one."""
    if code == EXIT_READ_BACK_MISMATCH:
        return 3
    if code == EXIT_PARTIAL:
        return 2
    if code == EXIT_CANNOT_TELL:
        return 1
    return 0


def _record(mut r: PublishReport, i: Int, o: FileOutcome):
    r.files[i].action = o.action.copy()
    r.files[i].state_after = o.state_after
    r.lines.append(o.line.copy())


def run_publish[T: PkgTransport, S: RegistryCredential, W: Sleeper](
    targets: List[PublishTarget],
    claims: List[String],
    mut registry: RegistrySet[T, PublishCredential],
    mut source: S,
    dry_run: Bool,
    opts: RunOptions,
    mut sleeper: W,
    var r: PublishReport,
) -> PublishReport:
    """Steps 1 to 6 (see the file header). `source` is asked ONCE for the
    write value, and only when the registry's credential is not armed yet
    and something is to be uploaded. Never raises."""
    r.dry_run = dry_run
    r.files = List[FileRow]()
    for i in range(len(targets)):
        r.files.append(FileRow(targets[i]))
    # ── step 1 ───────────────────────────────────────────────────────────────
    var channel_read = read_channel(registry, targets)
    for i in range(len(targets)):
        r.files[i].state_before = channel_read.states[i].kind
        r.files[i].state_after = channel_read.states[i].kind
    var verdict: Int
    try:
        var v = plan_from_state(targets, channel_read, claims)
        verdict = v.verdict
        for k in range(len(v.lines)):
            r.lines.append(v.lines[k].copy())
    except e:
        r.exit_code = EXIT_CANNOT_TELL
        r.lines.append(String(e))
        r.finish_line()
        return r^
    if verdict != VERDICT_PROCEED:
        r.exit_code = _exit_of_verdict(verdict)
        r.finish_line()
        return r^
    var to_upload = 0
    for i in range(len(targets)):
        var word = String("WOULD UPLOAD ") if channel_read.states[i].kind == STATE_ABSENT else String("PRESENT ")
        if channel_read.states[i].kind == STATE_ABSENT:
            to_upload += 1
        r.lines.append(word + targets[i].where() + String(" sha256=") + targets[i].sha256_hex)
    if dry_run:
        r.lines.append(
            String("DRY RUN: nothing was uploaded; ")
            + String(to_upload)
            + String(" file(s) would be, the metapackage last")
        )
        r.exit_code = EXIT_PUBLISHED
        r.finish_line()
        return r^
    # ── step 2 ───────────────────────────────────────────────────────────────
    try:
        var names = approved_names_for(targets, channel_read, claims)
        if not registry.credential().is_armed():
            var host = repo_host(targets[0].coordinate.repo)
            var auth = source.authorization(SURFACE_PREFIX_DEV, host)
            registry.credential().arm(auth^)
        for i in range(len(targets)):
            if targets[i].is_metapackage:
                continue
            if channel_read.states[i].kind == STATE_SAME:
                r.files[i].action = String("skipped")
                r.lines.append(String("SKIPPED ") + targets[i].where() + String(" -- already present, identical"))
                continue
            var o = upload_file(registry, targets[i], names, opts, sleeper)
            _record(r, i, o)
            if o.result != FILE_DONE:
                r.exit_code = _exit_of_file(o.result)
                for j in range(i + 1, len(targets)):
                    if channel_read.states[j].kind == STATE_ABSENT:
                        r.files[j].action = String("not-attempted")
                        r.lines.append(String("NOT-ATTEMPTED ") + targets[j].where())
                r.finish_line()
                return r^
        # ── step 3 ───────────────────────────────────────────────────────────
        var back = read_back_all(registry, targets)
        var worst = EXIT_PUBLISHED
        for i in range(len(targets)):
            if targets[i].is_metapackage:
                continue
            r.files[i].state_after = back[i].kind
            var code = EXIT_PUBLISHED
            if back[i].kind == STATE_DIFFERENT:
                code = EXIT_READ_BACK_MISMATCH
            elif back[i].kind == STATE_ABSENT:
                code = EXIT_PARTIAL
            elif back[i].kind != STATE_SAME:
                code = EXIT_CANNOT_TELL
            if code != EXIT_PUBLISHED:
                r.lines.append(
                    String("READ-BACK ")
                    + targets[i].where()
                    + String(": ")
                    + state_name(back[i].kind)
                    + String(" ")
                    + back[i].detail
                )
                if _read_back_rank(code) > _read_back_rank(worst):
                    worst = code
        if worst != EXIT_PUBLISHED:
            for i in range(len(targets)):
                if targets[i].is_metapackage:
                    r.files[i].action = String("not-attempted")
                    r.lines.append(String("NOT-ATTEMPTED ") + targets[i].where() + String(" -- the metapackage is published only after every member reads back"))
            r.exit_code = worst
            r.finish_line()
            return r^
        # ── step 4 ───────────────────────────────────────────────────────────
        for i in range(len(targets)):
            if not targets[i].is_metapackage:
                continue
            if channel_read.states[i].kind == STATE_SAME:
                var s = read_file_state(registry, targets[i])
                r.files[i].action = String("skipped")
                r.files[i].state_after = s.kind
                if s.kind != STATE_SAME:
                    r.exit_code = EXIT_READ_BACK_MISMATCH if s.kind == STATE_DIFFERENT else EXIT_CANNOT_TELL
                    r.lines.append(String("READ-BACK ") + targets[i].where() + String(": ") + state_name(s.kind))
                    r.finish_line()
                    return r^
                r.lines.append(String("SKIPPED ") + targets[i].where() + String(" -- already present, identical"))
                continue
            var o = upload_file(registry, targets[i], names, opts, sleeper)
            _record(r, i, o)
            if o.result != FILE_DONE:
                r.exit_code = _exit_of_file(o.result)
                r.finish_line()
                return r^
    except e:
        r.exit_code = EXIT_FAILED
        r.lines.append(String("FAILED -- ") + String(e))
        r.finish_line()
        return r^
    # ── step 5 (report-only) ─────────────────────────────────────────────────
    for i in range(len(targets)):
        r.files[i].indexed = is_indexed(registry, targets[i], opts, sleeper)
    r.exit_code = EXIT_PUBLISHED
    r.finish_line()
    return r^
