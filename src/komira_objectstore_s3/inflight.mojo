# =============================================================================
# komira_objectstore_s3/inflight.mojo -- run N jobs with at most K in flight
# =============================================================================
#
# komira_aws_core's send blocks its thread (store.mojo), so the one way to
# have K requests in flight is K threads, each sending over a store of its
# own. `run_bounded_inflight` is that: it runs jobs 0..n-1 on
# `inflight_workers(n, k)` threads (komira_fork_join), each thread taking the
# next job from a shared atomic counter and running it to completion before
# taking another. No more than that many jobs are ever running at once, and
# while jobs remain, every thread is running one.
#
# A job is identified by its index and runs on a worker index (0..workers-1),
# which a caller uses to pick the store that thread owns: worker `w` is the
# only thread that touches store `w`, so the stores need no lock.
#
# ONE WORKER IS THE CALLING THREAD. When at most one job may be in flight
# (k = 1, or n = 1), the jobs run in order on the caller's thread and no
# thread is started.
#
# FAILURE. A job that raises stops its thread; the other threads take no new
# job once any has failed (they finish the one they hold). After every thread
# has joined, the error of the lowest worker index that failed is raised,
# with the number of failed workers appended when more than one failed
# (komira_fork_join's rule). On the calling thread the first error is raised
# as it is.
# =============================================================================

from std.memory import Pointer

from komira_atomic_alias import AtomicI64
from komira_fork_join import ForkJoinBody, fork_join


trait InflightJobs(Movable):
    """N jobs that may run at once on distinct workers."""

    def run_job(self, worker: Int, job: Int) raises:
        """Runs job `job` on worker `worker`. Two calls running at once have
        different `worker`s and different `job`s."""
        ...


def inflight_workers(n_jobs: Int, max_inflight: Int) -> Int:
    """The workers `run_bounded_inflight` uses for `n_jobs` jobs under the
    bound `max_inflight`: `min(n_jobs, max_inflight)`, a bound below 1 read
    as 1, and 0 when there is no job."""
    if n_jobs <= 0:
        return 0
    return min(n_jobs, max(1, max_inflight))


struct _Pull[
    J: InflightJobs, jo: ImmutOrigin, no: MutOrigin, fo: MutOrigin
](ForkJoinBody):
    """One body shared by every thread: the jobs, the next job's index and
    the failure flag."""

    var jobs: Pointer[Self.J, Self.jo]
    var next: Pointer[AtomicI64, Self.no]
    var failed: Pointer[AtomicI64, Self.fo]
    var n_jobs: Int

    def __init__(
        out self,
        jobs: Pointer[Self.J, Self.jo],
        next: Pointer[AtomicI64, Self.no],
        failed: Pointer[AtomicI64, Self.fo],
        n_jobs: Int,
    ):
        self.jobs = jobs
        self.next = next
        self.failed = failed
        self.n_jobs = n_jobs

    def run(self, tid: Int) raises:
        while self.failed[].load() == 0:
            var job = Int(self.next[].fetch_add(1))
            if job >= self.n_jobs:
                return
            try:
                self.jobs[].run_job(tid, job)
            except e:
                _ = self.failed[].fetch_add(1)
                raise e^


def run_bounded_inflight[
    J: InflightJobs
](jobs: J, n_jobs: Int, max_inflight: Int) raises:
    """Runs jobs 0..`n_jobs`-1 with at most `max_inflight` running at once,
    on `inflight_workers(n_jobs, max_inflight)` workers (module header). A
    bound of 1, or a single job, runs on the calling thread as worker 0."""
    var workers = inflight_workers(n_jobs, max_inflight)
    if workers == 0:
        return
    if workers == 1:
        for job in range(n_jobs):
            jobs.run_job(0, job)
        return
    var next = AtomicI64(0)
    var failed = AtomicI64(0)
    var body = _Pull(Pointer(to=jobs), Pointer(to=next), Pointer(to=failed), n_jobs)
    fork_join(body, workers)
