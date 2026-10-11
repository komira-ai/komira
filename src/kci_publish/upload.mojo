# =============================================================================
# src/kci_publish/upload.mojo -- contract steps 2 to 4: upload the members
#   that are missing, read EVERY member back, then the metapackage, last.
# =============================================================================
#
# THE CREDENTIAL IS RESOLVED ONCE. `PublishCredential` presents one
# `Authorization` value for the channel's (surface, host): the read value
# (EMPTY = anonymous on a PUBLIC channel) until `arm` is given the write
# value, resolved ONCE from the channel's declared credential (an API token by
# secret name, or an OIDC exchange) before the first write. A request for any
# other surface or host is refused before it is sent.
#
# STEP 2 (`upload_members`): the members still absent go into one queue, in
# the order `resolve_targets` gave (libraries by fewer set-internal
# requirements first; a stable order, never a correctness rule), and
# min(`--concurrency`, queue length) workers pull from it on their own
# threads (`komira_fork_join`). Each worker owns its own `RegistrySet`: a
# transport from `ChannelTransport.for_worker` and a COPY of the credential
# that was resolved ONCE before the first write (`PublishCredential
# .for_worker`), so no request state is shared between threads. EVERY member
# in the queue is attempted, whatever another member's upload answered: the
# step-3 barrier is "every member's upload has returned", and a run with
# `--concurrency 1` must end in the same state as one with 4. Each outcome is
# written to the member's own slot; the run reads them after the join.
#
# PER MEMBER (`upload_file`):
#   * already present-same at step 1: not uploaded;
#   * one upload request per attempt, then `settle`: re-read BY DOWNLOAD,
#     polling while the channel lags, until present-same or
#     present-different or the last poll:
#       - present-same: done (whatever the upload answered: 201, a 409 from
#         an earlier attempt, a lost answer);
#       - present-different: STOP (exit 7) -- another file holds the name;
#       - absent or cannot-tell after an answer that was not definitive
#         (201, 409, 429, a 5xx, a lost answer): the next attempt, after a
#         bounded backoff (komira_retry `Backoff`). After the last attempt:
#         absent is PARTIAL (exit 9), cannot-tell is exit 5;
#   * a definitive refusal (400 and the other rejections, 401/403): FAILED
#     (exit 4). The other members are still attempted; the metapackage is
#     not.
#   ⛔ NEVER `force`: `kci_pkg_upload.PrefixDevRegistry` has no parameter that
#   sends it, and the welded tests assert it over every recorded request.
#
# STEP 3 (`read_back_all`): after every worker has returned, EVERY member is
# downloaded again, uploaded or not, and its sha256 compared. A mismatch is
# exit 10, a member still absent exit 9, an unreadable one exit 5, and the
# metapackage is not uploaded.
#
# STEP 4: only then the metapackage, by the same `upload_file`, and its own
# read-back.
#
# Encapsulation: owned values; the registry set is borrowed `mut` for each
# call. The worker pool is reached by the threads through one
# `Pointer[_Pool, origin]` (a tracked borrow of a local that outlives the
# join); each thread writes only its own worker slot and the outcome slots it
# dequeued. No raw pointer, no wildcard origin.
# =============================================================================

from std.memory import Pointer
from std.pathlib import Path

from komira_atomic_alias import AtomicI64
from komira_fork_join import ForkJoinBody, fork_join
from komira_retry import Backoff, Jitter, Sleeper, SplitMix64Rng

from kci_pkg_upload import (
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_UNKNOWN,
    ApprovedNames,
    PackageFile,
    PkgTransport,
    RegistryCredential,
    RegistrySet,
    upload_kind_name,
)
from kci_pkg_upload.credential import refuse_other_host, refuse_surface

from .channel_state import read_file_state
from .workers import (
    DEFAULT_CONCURRENCY,
    MAX_CONCURRENCY,
    MIN_CONCURRENCY,
    ChannelTransport,
    WorkerSleeper,
)
from .plan import (
    STATE_ABSENT,
    STATE_CANNOT_TELL,
    STATE_DIFFERENT,
    STATE_SAME,
    FileState,
    PublishTarget,
)


struct RunOptions(Copyable, Movable):
    """The bounds of the waits: `settle` polls up to `read_back_attempts`
    downloads `read_back_wait_ms` apart; an upload is attempted up to
    `upload_attempts` times with a backoff from `retry_initial_ms` to
    `retry_max_ms`; the index check polls up to `index_polls` times
    `index_wait_ms` apart; step 2 runs up to `concurrency` upload workers
    (`--concurrency`, clamped to 1..16). `never_backward`: the stage never
    publishes a lower build number than its channel lists for the same name
    and version (run.mojo, KCI-E-SUPERSEDED). `main_line_only`: that rule
    counts only the channel's main-line builds (plan.mojo
    `main_line_files`; a channel that also takes break-glass builds).

    Layout: Ints and Bools. No pointer field."""

    var read_back_attempts: Int
    var read_back_wait_ms: Int64
    var upload_attempts: Int
    var retry_initial_ms: Int64
    var retry_max_ms: Int64
    var index_polls: Int
    var index_wait_ms: Int64
    var seed: UInt64
    var concurrency: Int
    var never_backward: Bool
    var main_line_only: Bool

    def __init__(
        out self,
        read_back_attempts: Int = 6,
        read_back_wait_ms: Int64 = 10_000,
        upload_attempts: Int = 3,
        retry_initial_ms: Int64 = 2_000,
        retry_max_ms: Int64 = 30_000,
        index_polls: Int = 6,
        index_wait_ms: Int64 = 10_000,
        seed: UInt64 = 0x6B6369,
        concurrency: Int = DEFAULT_CONCURRENCY,
    ):
        self.read_back_attempts = read_back_attempts if read_back_attempts > 0 else 1
        self.read_back_wait_ms = read_back_wait_ms
        self.upload_attempts = upload_attempts if upload_attempts > 0 else 1
        self.retry_initial_ms = retry_initial_ms
        self.retry_max_ms = retry_max_ms if retry_max_ms >= retry_initial_ms else retry_initial_ms
        self.index_polls = index_polls if index_polls > 0 else 1
        self.index_wait_ms = index_wait_ms
        self.seed = seed
        var n = concurrency
        if n < MIN_CONCURRENCY:
            n = MIN_CONCURRENCY
        if n > MAX_CONCURRENCY:
            n = MAX_CONCURRENCY
        self.concurrency = n
        self.never_backward = False
        self.main_line_only = False


struct PublishCredential(RegistryCredential, Movable):
    """See the file header. Never printed; no accessor returns the value.

    Layout: Ints, Bools and owned Strings. No pointer field."""

    var _surface: Int
    var _host: String
    var _read: String
    var _write: String
    var _armed: Bool

    var _configured: Bool

    def __init__(out self):
        """Unconfigured: every request is refused until `configure`."""
        self._surface = -1
        self._host = String("")
        self._read = String("")
        self._write = String("")
        self._armed = False
        self._configured = False

    def configure(mut self, surface: Int, var host: String, var read_authorization: String):
        """Bind to the channel's (surface, host) and the value reads
        present (EMPTY = anonymous)."""
        self._surface = surface
        self._host = host^
        self._read = read_authorization^
        self._configured = True

    def arm(mut self, var write_authorization: String) raises:
        """Present `write_authorization` from now on. RAISES on an EMPTY one:
        an upload needs a credential."""
        if write_authorization.byte_length() == 0:
            raise Error(
                "PUBLISH step: the channel's credential resolved to nothing; an upload needs one"
            )
        self._write = write_authorization^
        self._armed = True

    def is_armed(self) -> Bool:
        return self._armed

    def for_worker(self) -> PublishCredential:
        """A copy for one upload worker: the same (surface, host) binding and
        the same values, resolved once by the run, never again."""
        var c = PublishCredential()
        c._surface = self._surface
        c._host = self._host.copy()
        c._read = self._read.copy()
        c._write = self._write.copy()
        c._armed = self._armed
        c._configured = self._configured
        return c^

    def authorization(mut self, surface: Int, host: String) raises -> String:
        if not self._configured:
            raise Error("PUBLISH step: the channel credential is not configured; the request was not sent")
        if surface != self._surface:
            refuse_surface(String("the PUBLISH step's channel credential"), surface)
        refuse_other_host(String("the PUBLISH step's channel credential"), surface, host, self._host)
        if self._armed:
            return self._write.copy()
        return self._read.copy()


comptime FILE_DONE: Int = 0
comptime FILE_STOP_DIFFERENT: Int = 1
comptime FILE_FAILED: Int = 2
comptime FILE_STILL_ABSENT: Int = 3
comptime FILE_CANNOT_TELL: Int = 4


struct FileOutcome(Copyable, Movable):
    """What step 2 or 4 did with one file: a FILE_* result, the effect word
    for the report, the state it ended in, and a line for a human.

    Layout: Ints and owned Strings. No pointer field."""

    var result: Int
    var effect: String
    var state_after: Int
    var line: String

    def __init__(out self, result: Int, var effect: String, state_after: Int, var line: String):
        self.result = result
        self.effect = effect^
        self.state_after = state_after
        self.line = line^


def settle[T: PkgTransport, C: RegistryCredential, W: Sleeper](
    mut registry: RegistrySet[T, C], t: PublishTarget, opts: RunOptions, mut sleeper: W
) raises -> FileState:
    """Download until present-same or present-different, or the last of
    `read_back_attempts` polls; return the last state."""
    var s = read_file_state(registry, t)
    var n = 1
    while n < opts.read_back_attempts:
        if s.kind == STATE_SAME or s.kind == STATE_DIFFERENT:
            break
        sleeper.sleep_ms(opts.read_back_wait_ms)
        s = read_file_state(registry, t)
        n += 1
    return s^


def package_file_of(t: PublishTarget) raises -> PackageFile:
    """The target's bytes, read now; RAISES when they no longer have the
    verified sha256 (the release directory changed under the run)."""
    var data = Path(t.file_path).read_bytes()
    var f = PackageFile(t.coordinate.copy(), data^, String(""))
    if f.identity.sha256_hex != t.sha256_hex:
        raise Error(
            String("'")
            + t.file_path
            + String("' changed after it was verified (sha256 now ")
            + f.identity.sha256_hex
            + String(")")
        )
    return f^


def upload_file[T: PkgTransport, C: RegistryCredential, W: Sleeper](
    mut registry: RegistrySet[T, C],
    t: PublishTarget,
    names: ApprovedNames,
    opts: RunOptions,
    mut sleeper: W,
) -> FileOutcome:
    """Step 2 for one file that step 1 read as absent (see the file header).
    Never raises: a local fault is FAILED, naming it."""
    var backoff: Backoff
    try:
        backoff = Backoff(opts.retry_initial_ms, 2.0, opts.retry_max_ms, Jitter.full())
    except e:
        return FileOutcome(FILE_FAILED, String("failed"), STATE_ABSENT, String("FAILED ") + t.where() + String(" -- ") + String(e))
    var rng = SplitMix64Rng(opts.seed)
    var last = FileState(STATE_ABSENT, String(""))
    var last_answer = String("")
    for attempt in range(opts.upload_attempts):
        if attempt > 0:
            try:
                sleeper.sleep_ms(backoff.delay_ms(attempt - 1, rng))
            except e:
                return FileOutcome(FILE_FAILED, String("failed"), last.kind, String("FAILED ") + t.where() + String(" -- ") + String(e))
        try:
            var f = package_file_of(t)
            var o = registry.upload(f, names)
            last_answer = upload_kind_name(o.kind) + String(" (HTTP ") + String(o.status) + String(")")
            if not (
                o.kind == UPLOAD_CREATED
                or o.kind == UPLOAD_DUPLICATE_REFUSED
                or o.kind == UPLOAD_UNKNOWN
                or o.kind == UPLOAD_RATE_LIMITED
            ):
                return FileOutcome(
                    FILE_FAILED,
                    String("failed"),
                    STATE_ABSENT,
                    String("FAILED ") + t.where() + String(" -- the channel answered ") + o.detail,
                )
            last = settle(registry, t, opts, sleeper)
        except e:
            return FileOutcome(FILE_FAILED, String("failed"), last.kind, String("FAILED ") + t.where() + String(" -- ") + String(e))
        if last.kind == STATE_SAME:
            return FileOutcome(
                FILE_DONE,
                String("uploaded"),
                STATE_SAME,
                String("UPLOADED ") + t.where() + String(" sha256=") + t.sha256_hex + String(" (") + last_answer + String(")"),
            )
        if last.kind == STATE_DIFFERENT:
            return FileOutcome(
                FILE_STOP_DIFFERENT,
                String("stopped"),
                STATE_DIFFERENT,
                String("STOP different bytes: ") + t.where() + String(" after ") + last_answer + String(": ") + last.detail,
            )
    if last.kind == STATE_ABSENT:
        return FileOutcome(
            FILE_STILL_ABSENT,
            String("missing"),
            STATE_ABSENT,
            String("MISSING ")
            + t.where()
            + String(" -- still absent after ")
            + String(opts.upload_attempts)
            + String(" upload attempt(s); the last answered ")
            + last_answer,
        )
    return FileOutcome(
        FILE_CANNOT_TELL,
        String("unconfirmed"),
        last.kind,
        String("CANNOT TELL ") + t.where() + String(" -- ") + last.detail,
    )


def read_back_all[T: PkgTransport, C: RegistryCredential](
    mut registry: RegistrySet[T, C], targets: List[PublishTarget]
) -> List[FileState]:
    """Step 3: download every non-metapackage target and compare (one read
    each; the uploads already waited out the channel's lag)."""
    var out = List[FileState]()
    for i in range(len(targets)):
        if targets[i].is_metapackage:
            out.append(FileState(STATE_ABSENT, String("not read: the metapackage is step 4")))
            continue
        out.append(read_file_state(registry, targets[i]))
    return out^


struct _Worker[T: ChannelTransport, W: WorkerSleeper](Movable):
    """One worker's own state: its registry set and its sleeper.

    Layout: owned values. No pointer field."""

    var registry: RegistrySet[Self.T, PublishCredential]
    var sleeper: Self.W

    def __init__(out self, var registry: RegistrySet[Self.T, PublishCredential], var sleeper: Self.W):
        self.registry = registry^
        self.sleeper = sleeper^


struct _Pool[T: ChannelTransport, W: WorkerSleeper](Movable):
    """Step 2's queue: `jobs` (target indices, in upload order), the next
    job to take, one worker per thread and one outcome per job.

    Layout: owned lists, an atomic and owned values. No pointer field."""

    var targets: List[PublishTarget]
    var jobs: List[Int]
    var names: ApprovedNames
    var opts: RunOptions
    var next: AtomicI64
    var workers: List[_Worker[Self.T, Self.W]]
    var outcomes: List[FileOutcome]

    def __init__(
        out self,
        var targets: List[PublishTarget],
        var jobs: List[Int],
        var names: ApprovedNames,
        var opts: RunOptions,
    ):
        self.targets = targets^
        self.jobs = jobs^
        self.names = names^
        self.opts = opts^
        self.next = AtomicI64(Int64(0))
        self.workers = List[_Worker[Self.T, Self.W]]()
        self.outcomes = List[FileOutcome]()
        for _ in range(len(self.jobs)):
            self.outcomes.append(
                FileOutcome(FILE_FAILED, String("not-attempted"), STATE_ABSENT, String("NOT-ATTEMPTED"))
            )


struct _UploadBody[T: ChannelTransport, W: WorkerSleeper, o: MutOrigin](ForkJoinBody):
    """What each worker thread runs: take the next job until none is left.

    Layout: one tracked `Pointer` to the run's local pool. No raw pointer."""

    var pool: Pointer[_Pool[Self.T, Self.W], Self.o]

    def __init__(out self, pool: Pointer[_Pool[Self.T, Self.W], Self.o]):
        self.pool = pool

    def run(self, tid: Int) raises:
        # Parallel region: thread `tid` writes only `workers[tid]` and
        # the `outcomes[k]` of the jobs `k` it took from the atomic counter
        # (each `k` is taken by exactly one thread). Neither list is resized
        # while the threads run. Everything else is read only.
        ref p = self.pool[]
        while True:
            var k = Int(p.next.fetch_add(Int64(1)))
            if k >= len(p.jobs):
                return
            ref w = p.workers[tid]
            p.outcomes[k] = upload_file(w.registry, p.targets[p.jobs[k]], p.names, p.opts, w.sleeper)


def upload_members[T: ChannelTransport, W: WorkerSleeper](
    mut registry: RegistrySet[T, PublishCredential],
    targets: List[PublishTarget],
    jobs: List[Int],
    names: ApprovedNames,
    opts: RunOptions,
    sleeper: W,
) raises -> List[FileOutcome]:
    """Step 2: upload `targets[jobs[k]]` for every `k` on min(concurrency,
    len(jobs)) workers (see the file header); return the outcomes in `jobs`
    order. `registry`'s credential must already be armed: it is copied, never
    resolved again. RAISES only when a worker cannot be made or started;
    nothing is uploaded then."""
    var pool = _Pool[T, W](targets.copy(), jobs.copy(), names.copy(), opts.copy())
    var n = opts.concurrency
    if n > len(jobs):
        n = len(jobs)
    for _ in range(n):
        var reg = RegistrySet[T, PublishCredential](
            registry.transport().for_worker(), registry.credential().for_worker()
        )
        pool.workers.append(_Worker[T, W](reg^, sleeper.for_worker()))
    var body = _UploadBody(Pointer(to=pool))
    fork_join(body, n)
    return pool.outcomes.copy()
