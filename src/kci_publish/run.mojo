# =============================================================================
# src/kci_publish/run.mojo -- `run_publish`: contract steps 1 to 6 over a set
#   that step 0 already verified, and the reason it stopped (`report.mojo`
#   maps a reason to an outcome).
# =============================================================================
#
#   1. read the channel (`channel_state.mojo`): every file by download, every
#      listed subdir's names; `plan_from_state` decides: STOP_DIFFERENT_BYTES,
#      CANNOT_TELL or ALREADY_PUBLISHED stop here with NO write request. The
#      names new to the channel go into the report whatever the verdict
#      (unless step 1 could not tell). NEVER BACKWARD: when the stage never
#      goes backward (`RunOptions.never_backward`) and the run would upload,
#      a listed build of ANY name and version with a HIGHER build number,
#      or an equal one of another build string (`plan.mojo`
#      `superseding_files`), or a NEWEST listed build whose commit is not on
#      the release revision's history (`history`, `plan.mojo`
#      `backward_files`) stops it REFUSED, KCI-E-SUPERSEDED, with NO write
#      request (a dry run too). When the channel lists a numbered build and
#      `history` was not read (empty), it stops CANNOT_TELL (exit 5), never a
#      pass. With `RunOptions.main_line_only` (a channel that also takes
#      break-glass builds: gamma) every rule here reads only the channel's
#      MAIN-LINE builds (`plan.mojo` `main_line_files`); the others are
#      reported (`OFF MAIN`) and never counted, and a main history that was
#      not read stops it CANNOT_TELL. THE SPLIT: a run the rules would refuse
#      asks git (`reader`, history.mojo) whether the release revision is on
#      the history of the commit each newest (main-line) build names:
#      every one descends from it -> SUPERSEDED (exit 0, nothing uploaded:
#      a newer release is already in this channel); any one unrelated, or
#      a newest build whose build string names no commit -> REFUSED,
#      KCI-E-SUPERSEDED (exit 3), as before; otherwise (a prefix git
#      cannot resolve to one commit, a shallow clone) CANNOT_TELL (exit 5),
#      never SUPERSEDED;
#   --plan stops here too, printing what steps 2 to 4 would do: no write
#      request, and `source` is never asked for a write value (a dry run's
#      credential probe is the flow's, before this);
#   2. the write credential is resolved ONCE (`PublishCredential.arm`), then
#      every member still absent is uploaded by up to `--concurrency` workers
#      (`upload.mojo`, `upload_members`). EVERY such member is attempted; when
#      any of them does not end present-same the run stops after all of them
#      returned, with the worst reason (STOP_DIFFERENT_BYTES over FAILED over
#      PARTIAL over CANNOT_TELL), and the metapackage is not attempted;
#   3. the barrier: when every worker has returned, EVERY member is
#      downloaded back and compared;
#   4. only then the metapackage, uploaded (or found present-same) and read
#      back;
#   5. report-only: is each file in its subdir's repodata yet (`index.mojo`);
#   6. the report (`report.mojo`): the reason, and every file's row.
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
from .history import HistoryReader, UnreadHistory
from .index import is_indexed
from .plan import (
    STATE_ABSENT,
    STATE_DIFFERENT,
    STATE_SAME,
    VERDICT_ALREADY_PUBLISHED,
    VERDICT_CANNOT_TELL,
    VERDICT_PROCEED,
    VERDICT_STOP_DIFFERENT,
    PublishTarget,
    approved_names_for,
    plan_from_state,
    state_name,
    build_number_of,
    previous_build_number,
    RevisionHistory,
    backward_files,
    main_line_files,
    newest_build_prefixes,
    newest_listed_build_number,
    off_main_files,
    superseding_files,
)
from kci_api import ERROR_CREDENTIAL, ERROR_SUPERSEDED

from .report import (
    REASON_ALREADY_PUBLISHED,
    REASON_CANNOT_TELL,
    REASON_FAILED,
    REASON_PARTIAL,
    REASON_PUBLISHED,
    REASON_READ_BACK_MISMATCH,
    REASON_REFUSED,
    REASON_STOP_DIFFERENT_BYTES,
    REASON_SUPERSEDED,
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


def _reason_of_verdict(verdict: Int) -> String:
    if verdict == VERDICT_STOP_DIFFERENT:
        return String(REASON_STOP_DIFFERENT_BYTES)
    if verdict == VERDICT_CANNOT_TELL:
        return String(REASON_CANNOT_TELL)
    if verdict == VERDICT_ALREADY_PUBLISHED:
        return String(REASON_ALREADY_PUBLISHED)
    return String(REASON_PUBLISHED)


def _reason_of_file(result: Int) -> String:
    if result == FILE_STOP_DIFFERENT:
        return String(REASON_STOP_DIFFERENT_BYTES)
    if result == FILE_FAILED:
        return String(REASON_FAILED)
    if result == FILE_STILL_ABSENT:
        return String(REASON_PARTIAL)
    if result == FILE_CANNOT_TELL:
        return String(REASON_CANNOT_TELL)
    return String(REASON_PUBLISHED)


def _step_two_rank(code: String) -> Int:
    """Step 2's precedence when several members did not end present-same:
    other bytes (a person's decision) over a definitive refusal over a
    member still missing over one that could not be read."""
    if code == REASON_STOP_DIFFERENT_BYTES:
        return 4
    if code == REASON_FAILED:
        return 3
    if code == REASON_PARTIAL:
        return 2
    if code == REASON_CANNOT_TELL:
        return 1
    return 0


def _read_back_rank(code: String) -> Int:
    """Step 3's precedence: a mismatch over a missing member over an
    unreadable one."""
    if code == REASON_READ_BACK_MISMATCH:
        return 3
    if code == REASON_PARTIAL:
        return 2
    if code == REASON_CANNOT_TELL:
        return 1
    return 0


def _record(mut r: PublishReport, i: Int, o: FileOutcome):
    r.files[i].effect = o.effect.copy()
    r.files[i].state_after = o.state_after
    r.lines.append(o.line.copy())


comptime _SPLIT_DESCENDS: Int = 0
comptime _SPLIT_UNRELATED: Int = 1
comptime _SPLIT_CANNOT_TELL: Int = 2


def _split_by_history[H: HistoryReader](
    listed: List[String], revision: String, mut reader: H, mut lines: List[String]
) -> Int:
    """THE SPLIT (file header): whether the release revision is on the
    history of every commit the newest of `listed` names. One line per
    newest build into `lines`."""
    var prefixes = newest_build_prefixes(listed)
    if len(prefixes) == 0 or revision.byte_length() == 0:
        lines.append(
            String("CANNOT TELL whether the channel's newest build descends from this release: no newest build or no")
            + String(" release revision to ask git about")
        )
        return _SPLIT_CANNOT_TELL
    var unrelated = False
    var cannot = False
    for i in range(len(prefixes)):
        ref p = prefixes[i]
        if p.byte_length() == 0:
            # a newest build whose name holds no commit cannot be shown to
            # descend: REFUSED, never SUPERSEDED
            unrelated = True
            lines.append(
                String("UNRELATED: a newest build of the channel names no commit, so it cannot be shown to descend")
                + String(" from this release's revision ") + revision
            )
            continue
        var commit: String
        try:
            commit = reader.commit_of(p)
        except e:
            cannot = True
            lines.append(
                String("CANNOT TELL whether the channel's newest build (commit ") + p
                + String(") descends from this release: ") + String(e)
            )
            continue
        var descends: Bool
        try:
            descends = reader.is_ancestor(revision, commit)
        except e:
            cannot = True
            lines.append(
                String("CANNOT TELL whether ") + commit + String(", the channel's newest build, descends from ")
                + revision + String(": ") + String(e)
            )
            continue
        if descends:
            lines.append(
                String("DESCENDS: the channel's newest build was built from ") + commit
                + String(", whose history holds this release's revision ") + revision
            )
        else:
            unrelated = True
            lines.append(
                String("UNRELATED: the channel's newest build was built from ") + commit
                + String(", whose history does not hold this release's revision ") + revision
            )
    if unrelated:
        return _SPLIT_UNRELATED
    if cannot:
        return _SPLIT_CANNOT_TELL
    return _SPLIT_DESCENDS


def run_publish[T: ChannelTransport, S: RegistryCredential, W: WorkerSleeper](
    targets: List[PublishTarget],
    mut registry: RegistrySet[T, PublishCredential],
    mut source: S,
    plan: Bool,
    opts: RunOptions,
    mut sleeper: W,
    var r: PublishReport,
    history: RevisionHistory = RevisionHistory(),
) -> PublishReport:
    """`run_publish_reading` with no history reader: a never-backward run
    the rules would refuse cannot tell (exit 5) instead of splitting."""
    var reader = UnreadHistory()
    return run_publish_reading(targets, registry, source, plan, opts, sleeper, r^, history, reader)


def run_publish_reading[T: ChannelTransport, S: RegistryCredential, W: WorkerSleeper, H: HistoryReader](
    targets: List[PublishTarget],
    mut registry: RegistrySet[T, PublishCredential],
    mut source: S,
    plan: Bool,
    opts: RunOptions,
    mut sleeper: W,
    var r: PublishReport,
    history: RevisionHistory,
    mut reader: H,
) -> PublishReport:
    """Steps 1 to 6 (see the file header). `source` is asked ONCE for the
    write value, and only when the registry's credential is not armed yet
    and something is to be uploaded; `reader` only for THE SPLIT. Never
    raises."""
    r.plan = plan
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
        var v = plan_from_state(targets, channel_read)
        verdict = v.verdict
        for k in range(len(v.lines)):
            r.lines.append(v.lines[k].copy())
        r.names_known = v.names_known
        r.new_names = v.new_names.copy()
    except e:
        r.lines.append(String(e))
        r.end(String(REASON_CANNOT_TELL))
        return r^
    if verdict != VERDICT_PROCEED:
        r.end(_reason_of_verdict(verdict))
        return r^
    if opts.never_backward:
        var listed = channel_read.listed_files.copy()
        if opts.main_line_only:
            if newest_listed_build_number(listed) >= 0 and len(history.main_line) == 0:
                r.lines.append(
                    String("CANNOT TELL which of the channel's builds are main's: main's history was not read (")
                    + history.main_unread + String("), and this run never goes backward, so nothing is uploaded")
                )
                r.end(String(REASON_CANNOT_TELL))
                return r^
            var off = off_main_files(listed, history.main_line)
            var would = superseding_files(targets, off)
            for k in range(len(would)):
                r.lines.append(String("OFF MAIN, not counted (a break-glass build of a branch): ") + would[k])
            listed = main_line_files(listed, history.main_line)
        var later = superseding_files(targets, listed)
        var newest = newest_listed_build_number(listed)
        if len(later) == 0 and newest >= 0 and len(history.commits) == 0:
            r.lines.append(
                String("CANNOT TELL whether this release descends from the channel's newest build (build number ")
                + String(newest) + String("): the release revision's history was not read (") + history.unread
                + String("), and this stage never goes backward, so nothing is uploaded")
            )
            r.end(String(REASON_CANNOT_TELL))
            return r^
        later.extend(backward_files(targets, listed, history.commits))
        if len(later) > 0:
            var why = List[String]()
            var split = _split_by_history(listed, history.revision, reader, why)
            if split == _SPLIT_DESCENDS:
                r.lines.extend(later^)
                r.lines.extend(why^)
                r.lines.append(
                    String("SUPERSEDED -- the channel's newest build descends from this release: a newer release")
                    + String(" already reached this channel, so this run uploads nothing and stops (exit 0)")
                )
                r.end(String(REASON_SUPERSEDED))
                return r^
            if split == _SPLIT_CANNOT_TELL:
                r.lines.extend(later^)
                r.lines.extend(why^)
                r.lines.append(
                    String("CANNOT TELL whether this release is superseded or refused, so nothing is uploaded")
                )
                r.end(String(REASON_CANNOT_TELL))
                return r^
            later.extend(why^)
            later.append(
                String("REFUSED -- the channel already lists a higher (or an equal, other) build number of any name or")
                + String(" version, or a build this revision does not descend from, and this stage never goes")
                + String(" backward: publish the newer release, or fix forward")
            )
            r.stop(String(REASON_REFUSED), String(ERROR_SUPERSEDED), String("\n").join(later))
            return r^
        # what this release carries (plan.mojo `previous_build_number`)
        if len(targets) > 0:
            r.build_number = build_number_of(targets[0])
        r.previous_build = previous_build_number(targets, listed)
    var to_upload = 0
    for i in range(len(targets)):
        var word = String("WOULD UPLOAD ") if channel_read.states[i].kind == STATE_ABSENT else String("PRESENT ")
        if channel_read.states[i].kind == STATE_ABSENT:
            to_upload += 1
        r.lines.append(word + targets[i].where() + String(" sha256=") + targets[i].sha256_hex)
    if plan:
        r.lines.append(
            String("DRY RUN: nothing was uploaded; ")
            + String(to_upload)
            + String(" file(s) would be, the metapackage last")
        )
        r.end(String(REASON_PUBLISHED))
        return r^
    # ── step 2 ───────────────────────────────────────────────────────────────
    try:
        var names = approved_names_for(targets)
        if not registry.credential().is_armed():
            try:
                var host = repo_host(targets[0].coordinate.repo)
                var auth = source.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().arm(auth^)
            except e:
                # nothing was sent: the write value is asked for before the first upload
                r.stop(
                    String(REASON_FAILED),
                    String(ERROR_CREDENTIAL),
                    String("FAILED -- the channel's credential: ") + String(e),
                )
                return r^
        var jobs = List[Int]()
        for i in range(len(targets)):
            if targets[i].is_metapackage:
                continue
            if channel_read.states[i].kind == STATE_SAME:
                r.files[i].effect = String("skipped")
                r.lines.append(String("SKIPPED ") + targets[i].where() + String(" -- already present, identical"))
                continue
            jobs.append(i)
        var outcomes = upload_members(registry, targets, jobs, names, opts, sleeper)
        var step_two = String(REASON_PUBLISHED)
        for k in range(len(jobs)):
            _record(r, jobs[k], outcomes[k])
            if outcomes[k].result != FILE_DONE:
                var code = _reason_of_file(outcomes[k].result)
                if _step_two_rank(code) > _step_two_rank(step_two):
                    step_two = code
        if step_two != REASON_PUBLISHED:
            for i in range(len(targets)):
                if targets[i].is_metapackage:
                    r.files[i].effect = String("not-attempted")
                    r.lines.append(String("NOT-ATTEMPTED ") + targets[i].where() + String(" -- the metapackage is published only after every member reads back"))
            r.end(step_two.copy())
            return r^
        # ── step 3 ───────────────────────────────────────────────────────────
        var back = read_back_all(registry, targets)
        var worst = String(REASON_PUBLISHED)
        for i in range(len(targets)):
            if targets[i].is_metapackage:
                continue
            r.files[i].state_after = back[i].kind
            var code = String(REASON_PUBLISHED)
            if back[i].kind == STATE_DIFFERENT:
                code = String(REASON_READ_BACK_MISMATCH)
            elif back[i].kind == STATE_ABSENT:
                code = String(REASON_PARTIAL)
            elif back[i].kind != STATE_SAME:
                code = String(REASON_CANNOT_TELL)
            if code != REASON_PUBLISHED:
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
        if worst != REASON_PUBLISHED:
            for i in range(len(targets)):
                if targets[i].is_metapackage:
                    r.files[i].effect = String("not-attempted")
                    r.lines.append(String("NOT-ATTEMPTED ") + targets[i].where() + String(" -- the metapackage is published only after every member reads back"))
            r.end(worst.copy())
            return r^
        # ── step 4 ───────────────────────────────────────────────────────────
        for i in range(len(targets)):
            if not targets[i].is_metapackage:
                continue
            if channel_read.states[i].kind == STATE_SAME:
                var s = read_file_state(registry, targets[i])
                r.files[i].effect = String("skipped")
                r.files[i].state_after = s.kind
                if s.kind != STATE_SAME:
                    r.lines.append(String("READ-BACK ") + targets[i].where() + String(": ") + state_name(s.kind))
                    r.end(String(REASON_READ_BACK_MISMATCH) if s.kind == STATE_DIFFERENT else String(REASON_CANNOT_TELL))
                    return r^
                r.lines.append(String("SKIPPED ") + targets[i].where() + String(" -- already present, identical"))
                continue
            var o = upload_file(registry, targets[i], names, opts, sleeper)
            _record(r, i, o)
            if o.result != FILE_DONE:
                r.end(_reason_of_file(o.result))
                return r^
    except e:
        r.lines.append(String("FAILED -- ") + String(e))
        r.end(String(REASON_FAILED))
        return r^
    # ── step 5 (report-only) ─────────────────────────────────────────────────
    for i in range(len(targets)):
        r.files[i].indexed = is_indexed(registry, targets[i], opts, sleeper)
    r.end(String(REASON_PUBLISHED))
    return r^
