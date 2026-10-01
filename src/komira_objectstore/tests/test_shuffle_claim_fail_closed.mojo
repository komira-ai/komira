# =============================================================================
# tests/test_shuffle_claim_fail_closed.mojo
#   Regression guard — the pull-via-claim path MUST FAIL CLOSED on a
#   non-EEXIST create failure.
# =============================================================================
#
# THE HAZARD (fail-open data loss). `claim_partition` is the create-CAS single-
# winner partition claim a `reduce_pool` worker uses to own a partition exactly
# once. It returns False on a precondition(412) — the EXPECTED loser outcome
# (another worker already claimed the partition). If a REAL IO failure
# (ENOSPC / EIO / EMFILE / EACCES) at the create-CAS were SWALLOWED and
# reported as a fake-412, `claim_partition` would return False ("lost") for a
# partition that NO worker actually claimed. Because a disk/permission failure is
# NOT worker-local, EVERY worker would fake-412 the SAME partition -> claimed by
# no one -> never processed -> SILENT WRONG RESULT (a missing partition in the
# reduce output). Contrast: the seal / `_entries` create-CAS path re-reads HEAD
# and fails loud on a 412, so it self-corrects.
#
# THE CONTRACT (fail-closed end-to-end):
#   * STORE (`_create_exclusive_and_write`): distinguish a TRUE create-loss
#     (EEXIST — the key already exists) from ANY OTHER create/write/fsync/close
#     failure. Only a TRUE create-loss raises the precondition(412); every other
#     failure raises a NON-precondition (transport/IO-shaped) Error.
#   * CLAIM (`claim_partition`): return False ONLY on a POSITIVELY-classified
#     precondition (via the canonical `_is_precondition`); RE-RAISE everything
#     else so a worker never silently skips a partition a real failure denied it.
#
# THIS TEST. It injects a NON-EEXIST
# create failure at the store's root, so `open(O_CREAT|O_EXCL)` for a FRESH key
# fails with something OTHER than EEXIST and the file is ABSENT afterwards. It
# asserts:
#   1. `conditional_put(create)` RAISES a NON-precondition Error (not a fake-412).
#   2. `claim_partition` RE-RAISES (does NOT return False = silent skip).
# A store that fake-412s violates both #1 and #2 (the store fake-412s, the
# claim returns False).
#
# ★ THE INJECTION IS `ENOTDIR`, NOT `chmod 0500`. A READ-ONLY root (chmod
# 0500) relies on `EACCES`, and a test runner executing as root (uid 0, as a
# remote-execution worker may) BYPASSES the directory write-permission check:
# the "denied" create SUCCEEDS and the guard fails because its INJECTION did not
# fire, not because the product regressed.
#
# This injection is a TYPE error, not a PERMISSION error, so root
# cannot bypass it: after the ctor creates the root DIRECTORY, we `rmdir` it and
# recreate the same path as a REGULAR FILE. `LocalFsConditionalStore` flat-
# encodes every key into ONE filename directly under the root (see
# `_mkdir_p_root`'s "keys are flat-encoded (no nested dirs)"), so the create then
# runs `open("<root-as-a-file>/<flat-key>", O_CREAT|O_EXCL)` -> **ENOTDIR** for
# every UID including 0, and the file is ABSENT afterwards.
#
# WHY THIS STILL FALSIFIES THE BUG (it is not a weaker assertion). The injection
# point is unchanged: `conditional_put` does NOT mkdir (only the ctor does), so
# control still reaches `_create_exclusive_and_write`, whose create-open fails
# and whose existence re-probe finds the path ABSENT. That is precisely the
# `_CREATE_IO_ERROR` arm. A store that caught ANY create-open failure and
# reported precondition(412) fake-412s on ENOTDIR exactly as it would on
# EACCES. We still use a FRESH key (never created), so the
# ONLY reason the create can fail is the injected ENOTDIR, never EEXIST.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns

from std.testing import assert_false, assert_true

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.shuffle_claim import claim_partition
from komira_objectstore.types import WritePrecondition
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR (through `test_tmpdir()`), NOT A HARD-CODED `/tmp` PATH.
#
# The same test may run in more than one action at a time on one machine. A
# fixed `/tmp` path is shared by every one of those executions; the runner's
# `TEST_TMPDIR` is private to each run, which is what makes them disjoint.
# `test_tmpdir()` raises when it is unset rather than fall back to `/tmp`.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# -----------------------------------------------------------------------------
# A per-process-unique scratch root under /tmp (the existing local-fs-store
# harness shape). Each test gets a distinct subdir so they never collide.
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (
        (_scratch_dir() + String("/komira_claim_failclosed_"))
        + tag
        + String("_")
        + String(t)
    )


def _bytes_from(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


# -----------------------------------------------------------------------------
# ENOTDIR injection helpers — turn the store's root from a DIRECTORY into a
# REGULAR FILE so the flat-key create-open fails with ENOTDIR (a type error the
# kernel enforces for EVERY uid, root included — unlike a permission bit).
# external_call is fine in TEST code (the encapsulation rule governs production
# module surfaces, not test injection).
# -----------------------------------------------------------------------------
def _rmdir(path: String) -> Int32:
    var p = path
    # SAFETY: synchronous rmdir(2); `p` pins the path bytes across the syscall;
    # the kernel copies the NUL-terminated path and returns. No pointer escapes.
    return external_call["rmdir", Int32](p.as_c_string_slice().unsafe_ptr())


def _unlink(path: String) -> Int32:
    var p = path
    # SAFETY: synchronous unlink(2); same pinning argument as `_rmdir`.
    return external_call["unlink", Int32](p.as_c_string_slice().unsafe_ptr())


def _make_root_a_regular_file(root: String) raises:
    """Replace the (empty, ctor-created) root DIRECTORY with a REGULAR FILE at
    the same path. Every subsequent `open("<root>/<flat-key>", O_CREAT|O_EXCL)`
    then fails ENOTDIR with the target ABSENT — the non-EEXIST create failure
    under test. Raises if the setup itself fails, so a broken injection is LOUD
    and can never be mistaken for the behavior under test (a chmod-based
    injection is a no-op when the test runs as root)."""
    # `rmdir` succeeds ONLY on an existing EMPTY DIRECTORY, so a 0 return is
    # itself the proof that the root WAS the ctor-created dir and is now gone.
    var rc = _rmdir(root)
    if Int(rc) != 0:
        raise Error(
            "test setup: rmdir on the fresh store root failed (rc="
            + String(Int(rc))
            + ") — cannot inject the non-EEXIST create failure"
        )
    # Recreate the SAME path as a regular file. `open(..., "w")` creates a
    # REGULAR file (it would raise on a directory), so after this returns the
    # root is unambiguously a file — no further probe is needed, and any failure
    # RAISES out of the setup rather than silently leaving a working directory
    # (the failure mode the chmod injection had).
    var fh = open(root, "w")
    fh.close()


# -----------------------------------------------------------------------------
# REGRESSION 1 — the STORE must raise a NON-precondition on a non-EEXIST create
# failure (NOT a fake-412). This is the root-cause guard: if
# `_create_exclusive_and_write` reverts to swallowing the EACCES into a
# fake-412, this test FAILS.
# -----------------------------------------------------------------------------
def test_store_conditional_create_non_eexist_failure_is_not_precondition() raises:
    var root = _scratch_root(String("store"))
    var store = LocalFsConditionalStore(root.copy())  # ctor mkdirs the root
    _make_root_a_regular_file(root)

    var raised = False
    var was_precondition = False
    try:
        # FRESH key (never created) under a root that is now a REGULAR FILE ->
        # O_CREAT|O_EXCL fails with ENOTDIR, file absent. A correct store reports
        # this as a real IO error, NOT a precondition(412).
        var _m = store.conditional_put(
            Path.parse(String("fresh/never_created.claim")),
            _bytes_from(String("x")),
            WritePrecondition.if_none_match_star(),
        )
    except e:
        raised = True
        var msg = String(e)
        if (
            (msg.find(String("precondition")) >= 0)
            or (msg.find(String("Precondition")) >= 0)
            or (msg.find(String("412")) >= 0)
        ):
            was_precondition = True

    # The create MUST raise (it could not succeed — the root is a FILE).
    assert_true(raised)
    # And it MUST NOT be classified as a precondition / 412 (the bug = fake-412).
    assert_false(was_precondition)

    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# REGRESSION 2 (THE HEADLINE) — `claim_partition` must RE-RAISE on a non-EEXIST
# create failure, NEVER return False. A False here is the fail-open data-loss
# bug: the worker would treat the partition as "already claimed by someone else"
# and SKIP it, but no one claimed it.
# -----------------------------------------------------------------------------
def test_claim_partition_reraises_on_non_eexist_failure() raises:
    var root = _scratch_root(String("claim"))
    var store = LocalFsConditionalStore(root.copy())
    _make_root_a_regular_file(root)

    var returned_false = False
    var reraised = False
    var reraised_non_precondition = False
    try:
        # partition_id chosen fresh; its `_claims/{pid}` key was never created,
        # so the ONLY reason the claim's create can fail is the root-swapped-to-
        # a-regular-file (ENOTDIR) — never EEXIST. A correct claim_partition
        # RE-RAISES.
        var won = claim_partition(
            store, Int64(7), Int64(0), Int64(3)
        )
        # Reaching here means the claim did NOT raise. The bug returns False
        # (silent skip); a correct claim cannot return True (the create failed).
        returned_false = not won
    except e:
        reraised = True
        var msg = String(e)
        if not (
            (msg.find(String("precondition")) >= 0)
            or (msg.find(String("Precondition")) >= 0)
            or (msg.find(String("412")) >= 0)
        ):
            reraised_non_precondition = True

    # The claim MUST re-raise (fail closed), NOT return a value.
    assert_true(reraised)
    assert_false(returned_false)
    # And the re-raised error MUST NOT be a precondition (it is a real IO error).
    assert_true(reraised_non_precondition)

    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# CONTROL — a TRUE create-loss (EEXIST: the claim key already exists) MUST still
# return False (won-by-someone-else). This pins that the fix did NOT break the
# legitimate loser path — only the non-EEXIST-failure path changed.
# -----------------------------------------------------------------------------
def test_claim_partition_true_eexist_loss_still_returns_false() raises:
    var root = _scratch_root(String("eexist"))
    var store = LocalFsConditionalStore(root.copy())

    # First claim WINS (creates the `_claims/{pid}` object).
    var won_first = claim_partition(store, Int64(9), Int64(0), Int64(2))
    assert_true(won_first)
    # Second claim of the SAME partition is a TRUE EEXIST loss -> returns False
    # (no raise) — the expected loser outcome the elastic pull relies on.
    var won_second = claim_partition(store, Int64(9), Int64(0), Int64(2))
    assert_false(won_second)

    _ = store^
    _cleanup(root)


def _cleanup(root: String):
    """Best-effort cleanup of the scratch root. After an ENOTDIR-injecting test
    the root is a REGULAR FILE, so `unlink` is the removal; after a normal test
    it is a directory whose objects are deleted through the store."""
    # ENOTDIR-injecting tests leave the root as a REGULAR FILE: `unlink` removes
    # it and the store-based sweep below is a no-op. Non-injecting tests leave a
    # DIRECTORY: `unlink` fails harmlessly and the sweep does the work. Both
    # orders are safe, so just try both.
    _ = _unlink(root)
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


def main() raises:
    test_store_conditional_create_non_eexist_failure_is_not_precondition()
    test_claim_partition_reraises_on_non_eexist_failure()
    test_claim_partition_true_eexist_loss_still_returns_false()
    print("[test_shuffle_claim_fail_closed] all 3 tests PASS")
