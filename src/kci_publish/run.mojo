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
#      every member still absent is uploaded by up to `--concurrency` workers
#      (`upload.mojo`, `upload_members`). EVERY such member is attempted; when
#      any of them does not end present-same the run stops after all of them
#      returned, with the worst outcome's exit code (7 over 4 over 9 over 5),
#      and the metapackage is not attempted;
#   3. the barrier: when every worker has returned, EVERY member is
#      downloaded back and compared;
#   4. only then the metapackage, uploaded (or found present-same) and read
#      back;
#   5. report-only: is each file in its subdir's repodata yet (`index.mojo`);
#   6. the report (`report.mojo`).
#
# `--concurrency 1` and `--concurrency 4` end in the same channel state and
# the same report: which thread uploads a member never changes what happens
# to it (each member has its own retries, its own settle, its own slot).
#
# Encapsulation: owned values; the registry set and the credential source are
# borrowed `mut`. No pointer, no wildcard origin.
# =============================================================================

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
    upload_members,
    read_back_all,
)
from .workers import ChannelTransport, WorkerSleeper


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


def _step_two_rank(code: Int) -> Int:
    """Step 2's precedence when several members did not end present-same:
    other bytes (a person's decision) over a definitive refusal over a
    member still missing over one that could not be read."""
    if code == EXIT_STOP_DIFFERENT_BYTES:
        return 4
    if code == EXIT_FAILED:
        return 3
    if code == EXIT_PARTIAL:
        return 2
    if code == EXIT_CANNOT_TELL:
        return 1
    return 0


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


def run_publish[T: ChannelTransport, S: RegistryCredential, W: WorkerSleeper](
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
        var jobs = List[Int]()
        for i in range(len(targets)):
            if targets[i].is_metapackage:
                continue
            if channel_read.states[i].kind == STATE_SAME:
                r.files[i].action = String("skipped")
                r.lines.append(String("SKIPPED ") + targets[i].where() + String(" -- already present, identical"))
                continue
            jobs.append(i)
        var outcomes = upload_members(registry, targets, jobs, names, opts, sleeper)
        var step_two = EXIT_PUBLISHED
        for k in range(len(jobs)):
            _record(r, jobs[k], outcomes[k])
            if outcomes[k].result != FILE_DONE:
                var code = _exit_of_file(outcomes[k].result)
                if _step_two_rank(code) > _step_two_rank(step_two):
                    step_two = code
        if step_two != EXIT_PUBLISHED:
            for i in range(len(targets)):
                if targets[i].is_metapackage:
                    r.files[i].action = String("not-attempted")
                    r.lines.append(String("NOT-ATTEMPTED ") + targets[i].where() + String(" -- the metapackage is published only after every member reads back"))
            r.exit_code = step_two
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
