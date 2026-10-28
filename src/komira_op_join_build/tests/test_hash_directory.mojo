# =============================================================================
# test_hash_directory -- `HashDirectory`, the packed directory of the untyped
# hash tables: insert and find, the salt surviving a slot rewrite, and the
# encoding invariants of the packed entry (slot 0 is not empty, a fresh or
# doubled directory is empty over dirty memory, an erase keeps the salt).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_op_join_build.hash_directory import HashDirectory, SLOT_EMPTY


# -----------------------------------------------------------------------------
# Smoke: insert and find.
# -----------------------------------------------------------------------------


def test_hash_directory_smoke() raises:
    """Insert + probe a few entries into HashDirectory."""
    var dir = HashDirectory(64)
    assert_equal(dir.capacity(), 64, "rounded-up to 64")
    assert_equal(dir.n_used, 0, "empty start")

    _ = dir.insert_raw(UInt64(0x12345678), Int32(0))
    _ = dir.insert_raw(UInt64(0xABCDEF01), Int32(1))
    assert_equal(dir.n_used, 2, "2 entries after 2 inserts")

    # Probe by walking the chain manually (testing the primitive's
    # composability since the FIRST-MATCH semantics live in the
    # JoinBuildTable_Untyped caller).
    var bucket = dir.bucket_of(UInt64(0x12345678))
    var s = dir.read_slot_at(bucket)
    assert_true(Int(s) != Int(SLOT_EMPTY), "first hash finds something")


def test_hash_directory_salt_survives_slot_rewrite() raises:
    """PROBE-PACK falsifier.

    The directory has ONE `_entries` buffer of `salt << 48 | slot` words and
    `_write_slot` keeps the salt (`keep` term), so assertion 2 below is live
    and the sabotage recipe in the closing paragraph is runnable as written.

    **This test binds in either layout.** Assertion 2 is trivially satisfied
    by two separate arrays; assertions 1 and 3 — that `read_salt_at`
    DISCRIMINATES — bind equally hard in both, and they are the ones no output
    oracle can reach.

    ---

    The packed directory put `salt << 48 | slot` into ONE 8-byte entry, so the
    two fields shared a word and a careless slot write CLOBBERED the salt. That
    hazard did not exist while they were two arrays — and does not exist today.

    ⚠ MEASURED BY SABOTAGE **on the packed layout**, and the first draft of this
    docstring was WRONG about it: zeroing `_write_slot`'s `keep` term reds BOTH
    this test and the
    pre-existing `test_composite_2_duplicate_keys_flag` (line 453) — a clobbered
    stored salt no longer matches the probe salt, the chain-head is missed, and
    the JOIN returns the wrong answer. So a salt clobber is a CORRECTNESS bug
    and the suite already caught it. The draft claimed the suite could not see
    it; that was a guess, and running the sabotage is what corrected it.

    What the suite still could NOT see, and what this test adds, is whether
    `read_salt_at` DISCRIMINATES. An accessor that returned, for every bucket,
    whatever salt the current probe is looking for would be perfectly CORRECT —
    every candidate would simply fall through to a full key compare — and it
    would silently disable the fingerprint that the whole packed layout exists
    to make cheap. That is §9's failure class: a de-optimisation an output
    oracle cannot observe.

    THE PROBE IS ESTABLISHED BEFORE THE PROPERTY, three ways:
      1. DIFFERENTIAL ORACLE — two hashes differing ONLY in their top 16 bits
         must yield DIFFERENT salts. Without this, a dead `read_salt_at` that
         always returns 0 passes every other assertion here.
      2. THE INVARIANT — `set_slot_at` rewrites the slot of an OCCUPIED bucket
         (the join chain-head promotion) and its docstring promises the salt is
         untouched. Assert the salt is byte-identical across that rewrite.
      3. KNOWN-NONZERO CONTROL — the salt read back must be non-zero for a hash
         whose top 16 bits are non-zero, so a buffer of zeroes fails.

    Sabotage run against the packed layout (reverted with a scripted edit):
    `var keep = UInt64(0)` in
    `HashDirectory._write_slot` reds assertion 2 with `AssertionError ...
    set_slot_at CLOBBERED the salt`, and `test_composite_2_duplicate_keys_flag`
    alongside it. Restoring the term returned the suites to PASSED.
    """
    var dir = HashDirectory(64)

    # Two hashes with the SAME low bits (so they start at the same bucket and
    # must probe apart) and DIFFERENT top-16 bits (so their salts must differ).
    var h_a = UInt64(0xAAAA_0000_0000_0021)
    var h_b = UInt64(0x5555_0000_0000_0021)

    var b_a = dir.insert_raw(h_a, Int32(7))
    var b_b = dir.insert_raw(h_b, Int32(8))
    assert_true(b_a != b_b, "same low bits must collide then probe apart")

    var salt_a = dir.read_salt_at(b_a)
    var salt_b = dir.read_salt_at(b_b)

    # (1) differential oracle — the accessor must DISCRIMINATE.
    assert_true(
        salt_a != salt_b,
        (
            "read_salt_at must distinguish two hashes differing in the top 16"
            " bits (a dead accessor returning a constant passes everything"
            " else here)"
        ),
    )
    # (3) known-nonzero control — a zeroed buffer must not pass.
    assert_true(Int(salt_a) != 0, "salt of 0xAAAA.... must be non-zero")
    assert_true(Int(salt_b) != 0, "salt of 0x5555.... must be non-zero")

    assert_equal(Int(dir.read_slot_at(b_a)), 7, "slot A round-trips")
    assert_equal(Int(dir.read_slot_at(b_b)), 8, "slot B round-trips")

    # (2) THE INVARIANT the pack could break: rewrite the slot in place; the
    # salt must be byte-identical afterwards, and the neighbour untouched.
    dir.set_slot_at(b_a, Int32(99))
    assert_equal(Int(dir.read_slot_at(b_a)), 99, "set_slot_at rewrote the slot")
    assert_equal(
        Int(dir.read_salt_at(b_a)),
        Int(salt_a),
        (
            "set_slot_at CLOBBERED the salt — the packed entry's upper 16 bits"
            " must survive a slot-only rewrite"
        ),
    )
    assert_equal(
        Int(dir.read_salt_at(b_b)), Int(salt_b), "neighbour bucket untouched"
    )
    assert_equal(Int(dir.read_slot_at(b_b)), 8, "neighbour slot untouched")
    assert_equal(dir.n_used, 2, "set_slot_at does not change the bucket count")


# =============================================================================
# THE PACKED ENTRY'S ENCODING INVARIANTS.
#
# ⛔ WHY THE REST OF THE SUITE DOES NOT COVER THEM. `HashDirectory`'s accessors
# hide the wire format, so every value-shaped assertion in this file passes
# over ANY encoding as long as the writer and the reader agree. Three failures
# survive that agreement and each has its own test below:
#
#   * SLOT 0 MUST NOT READ AS EMPTY. Today it cannot — the empty sentinel is
#     `0xFFFF_FFFF` and slot 0 stores as `0` — and this test is what keeps it
#     that way: ANY future re-encoding that makes the empty code collide with
#     slot 0 (an all-zero sentinel is exactly that) makes the bucket holding
#     group 0 read back EMPTY, so the next probe of that key MISSES and the
#     group silently DUPLICATES. Nothing about slot 0 is special in any other
#     fixture, which is why every one of them stays green: the first key
#     inserted into a fresh table is exactly the one no assertion re-probes.
#   * THE CLEAR STOPS CLEARING. `__init__` / `reset_doubled` must WRITE
#     `_ENTRY_EMPTY` into every bucket. Delete the fill and the directory
#     inherits whatever the allocator handed back — and a FRESH page is zeros,
#     which under some encodings is correct by accident. A test that does not
#     DIRTY the allocator first cannot see it.
#   * AN ERASE IS NOT THE SENTINEL WORD. `_write_slot(b, SLOT_EMPTY)` clears
#     the slot half and KEEPS the salt, so the entry word is not equal to
#     `_ENTRY_EMPTY` while the bucket IS empty. Every empty test masks the LOW
#     32 BITS for that reason; a "simplification" to a whole-word compare is
#     what this pins.
#
# MUTATION-CHECKED: each per-test docstring below names its own mutant and the
# OBSERVED verdict. `insert_at_known_empty` and the raw-word probe loop are
# reached only from the grouping table's combine path, not from this file: a
# mutation to either passes every test here.
# =============================================================================


def _dirty_the_allocator(nbytes: Int) raises:
    """Allocate `nbytes` through the SAME path `HashDirectory` uses, write a
    non-zero pattern over all of it, and drop it.

    ⭐ THIS IS THE NON-VACUITY GUARD FOR EVERY "the clear cleared" ASSERTION
    BELOW. `OwnedAlignedBuffer` allocates through `List[UInt8]` +
    `resize(unsafe_uninit_length=)` — i.e. tcmalloc, UNINITIALISED. A fresh
    page from the OS is zero-filled by the kernel, so a directory whose fill
    was deleted still reads all-empty and the test passes over a bug. Freeing
    a same-size-class block immediately before means the thread cache hands
    that block straight back (LIFO), so the next allocation starts DIRTY and
    the missing fill is observable.

    ⚠ It is a PROBABILISTIC guard, not a proof: nothing in the allocator's
    contract promises the reuse. It fails toward a VACUOUS PASS, never toward
    a false failure — so a green here is weaker than a red, and that is stated
    rather than assumed. The mutation was RUN (see the class docstring above);
    it went red.

    The pattern is deliberately NOT all-`0xFF`: a 0xFFFFFFFF slot code would
    decode to a value near Int32 overflow, and the point is to observe a
    plain wrong slot, not a conversion edge.
    """
    var dirt = OwnedAlignedBuffer(nbytes)
    var n_words = nbytes // 8
    for i in range(n_words):
        dirt.write_u64_le_at(i * 8, UInt64(0x0102030405060708))
    # `dirt` drops here, returning the block to the thread cache.
    _ = dirt^


def test_hash_directory_fresh_is_empty_over_dirty_memory() raises:
    """A freshly constructed directory reads EMPTY at every bucket, even when
    the allocator hands back a dirty block.

    MUTATION: delete `self._entries.zero()` from `HashDirectory.__init__`.

    ⚠⚠ OBSERVED VERDICT: RED **BY HANG**, NOT BY THIS ASSERTION, and the first
    draft of this docstring predicted the wrong one. The suite never reaches
    this test: an earlier case builds a real join table, `insert_raw`'s linear
    probe finds no empty bucket in a directory full of allocator garbage, and
    the loop does not terminate (measured 2026-09-08: killed at 45 s locally,
    1,533 s on the farm before it was interrupted). That is a genuine RED — a
    hung test is a failed test, and an unterminating probe is the worst shape
    the missing clear can take — but it is carried by the pre-existing cases,
    not by the line below.

    What this test adds is the DIAGNOSIS: it is the one case that says *the
    directory is not empty* rather than hanging, so a reader who sees the hang
    can run this case alone and get a message. Keep it, and keep the timeout in
    the run recipe at the top of this block.

    ⚠ The `_dirty_the_allocator` call is load-bearing and must not be deleted
    as noise — without it this test is green under that mutation on any fresh
    page. See `_dirty_the_allocator`'s docstring.
    """
    var cap = 1024
    _dirty_the_allocator(cap * 8)

    var dir = HashDirectory(cap)
    assert_equal(dir.capacity(), cap, "capacity is the requested power of 2")
    assert_equal(dir.n_used, 0, "a fresh directory holds nothing")

    var n_nonempty = 0
    for b in range(cap):
        if Int(dir.read_slot_at(b)) != Int(SLOT_EMPTY):
            n_nonempty += 1
    assert_equal(
        n_nonempty,
        0,
        (
            "a bucket of a FRESH directory is not empty — the fill loop in"
            " HashDirectory.__init__ did not run (or the empty sentinel and"
            " the clear disagree)"
        ),
    )


def test_hash_directory_slot_zero_is_findable() raises:
    """⛔ SLOT 0 MUST READ BACK AS SLOT 0, NOT AS SLOT_EMPTY — the one failure
    the rest of the suite cannot see.

    Under the current encoding (low 32 bits = the raw slot, empty =
    `0xFFFF_FFFF`) this holds trivially, and that is the point: this test is
    the STANDING GUARD on the property, not a test of one implementation. Any
    re-encoding that lets the empty code collide with slot 0 — an ALL-ZERO
    sentinel is exactly that, and was tried and reverted; see `_ENTRY_EMPTY` —
    makes the bucket holding group 0 read EMPTY, so a re-probe of key 0 MISSES
    and inserts a DUPLICATE GROUP. That is a wrong ANSWER, not a wrong layout.

    MUTATION (against the slot-code encoding this test arrived
    with): drop the `+ 1` in `HashDirectory.insert_raw`'s store. RED here with
    `slot 0 read back as SLOT_EMPTY`, and GREEN in every other fixture in this
    file, because none of them re-probes the first key it inserted.
    """
    var dir = HashDirectory(64)
    var h = UInt64(0xAAAA_0000_0000_0021)
    var b = dir.insert_raw(h, Int32(0))

    assert_true(
        Int(dir.read_slot_at(b)) != Int(SLOT_EMPTY),
        (
            "slot 0 read back as SLOT_EMPTY — the empty code and slot 0"
            " collide, so group 0 is invisible and silently duplicates on the"
            " next probe"
        ),
    )
    assert_equal(Int(dir.read_slot_at(b)), 0, "slot 0 round-trips as 0")
    assert_equal(dir.n_used, 1, "one bucket claimed")

    # The neighbour the probe would step to must still be empty, so a
    # "read_slot_at returns 0 for everything" mutation cannot pass the above.
    assert_equal(
        Int(dir.read_slot_at(dir.next_bucket(b))),
        Int(SLOT_EMPTY),
        "the next bucket on the chain is untouched (control for the assertion"
        " above: a constant-returning accessor must not pass)",
    )


def test_hash_directory_slot_code_boundaries_roundtrip() raises:
    """Slot values at both ends of the encodable range round-trip exactly.

    0, 1 and 2 pin the low end — where any off-by-one in a future encoding
    aliases onto the empty code — and 0x7FFF_FFFE pins that a large positive
    Int32 slot survives the pack without spilling into the salt half or into
    the sign bit.

    MUTATION (against the slot-code encoding this test arrived
    with): drop the `- 1` in `HashDirectory._read_slot`. RED here on the first
    assertion with an off-by-one. The assertions are encoding-agnostic and
    bind the raw-slot encoding equally.
    """
    var dir = HashDirectory(256)
    var slots = List[Int32]()
    slots.append(Int32(0))
    slots.append(Int32(1))
    slots.append(Int32(2))
    slots.append(Int32(0x7FFF_FFFE))

    var buckets = List[Int]()
    for i in range(len(slots)):
        # Distinct hashes so the four entries take four buckets.
        var h = UInt64(0x1111_0000_0000_0000) * UInt64(i + 1) + UInt64(i * 7)
        buckets.append(dir.insert_raw(h, slots[i]))

    for i in range(len(slots)):
        assert_equal(
            Int(dir.read_slot_at(buckets[i])),
            Int(slots[i]),
            (
                "slot round-trip failed — `_write_slot`'s encode and"
                " `_read_slot`'s decode disagree"
            ),
        )


def test_hash_directory_erase_keeps_salt_and_reads_empty() raises:
    """An ERASED bucket reads empty while KEEPING its salt — so the entry word
    is non-zero and the empty test must mask the LOW 32 BITS.

    MUTATION: `var keep = UInt64(0)` in `_write_slot`, i.e. an erase (or any
    slot rewrite) that drops the salt. RED here with `an erase CLOBBERED the
    salt`, alongside `test_hash_directory_salt_survives_slot_rewrite` and
    `test_composite_2_duplicate_keys_flag` — 3 of 16, observed 2026-09-08.

    ⚠ WHAT THIS DOES **NOT** BIND, STATED RATHER THAN ASSUMED: replacing
    `_read_slot`'s low-32 empty test with a whole-word compare against
    `_ENTRY_EMPTY` is NOT established as caught here. On an erased bucket the
    word is `salt << 48 | 0xFFFF_FFFF`, which is not `_ENTRY_EMPTY`, so the
    whole-word compare falls through to the return — but the value it returns
    is `Int32` of `0xFFFF_FFFF`, i.e. -1 again, so the mutant may well stay
    GREEN. That was measured for the slot-code encoding (GREEN) and has NOT
    been re-measured here. The low-32 masking is kept because it is what a
    future empty test that does not also decode would need; do not cite this
    test as covering it.
    """
    var dir = HashDirectory(64)
    var h = UInt64(0xBEEF_0000_0000_0031)
    var b = dir.insert_raw(h, Int32(5))
    var salt = dir.read_salt_at(b)
    assert_true(Int(salt) != 0, "fixture: the salt under test is non-zero")

    dir.set_slot_at(b, SLOT_EMPTY)
    assert_equal(
        Int(dir.read_slot_at(b)),
        Int(SLOT_EMPTY),
        "an erased bucket must read SLOT_EMPTY",
    )
    assert_equal(
        Int(dir.read_salt_at(b)),
        Int(salt),
        (
            "an erase CLOBBERED the salt — `_write_slot` promises to preserve"
            " the upper 16 bits"
        ),
    )


def test_hash_directory_reset_doubled_clears_over_dirty_memory() raises:
    """`reset_doubled` re-allocates and CLEARS — every bucket of the doubled
    directory reads empty, and the keys re-inserted afterwards all probe back.

    MUTATION: delete `self._entries.zero()` from
    `HashDirectory.reset_doubled`. RED here with `a bucket of the DOUBLED
    directory is not empty`.

    ⚠ `reset_doubled` is the hot half — `_rehash_directory` calls it once per
    doubling and it is where the deleted scalar store loop lived — so it needs
    its own witness; the `__init__` test above does not cover it.
    """
    var cap = 512
    var dir = HashDirectory(cap)

    # Populate under the grow threshold, remembering (hash, slot) so the
    # re-insert can be verified rather than assumed.
    var hashes = List[UInt64]()
    var n = cap // 4
    for i in range(n):
        var h = UInt64(0x9E37_79B9_7F4A_7C15) * UInt64(i + 1)
        hashes.append(h)
        _ = dir.insert_raw(h, Int32(i))
    assert_equal(dir.n_used, n, "fixture: every insert claimed a bucket")

    _dirty_the_allocator(cap * 2 * 8)
    dir.reset_doubled()

    assert_equal(dir.capacity(), cap * 2, "capacity doubled")
    assert_equal(dir.n_used, 0, "reset_doubled discards every entry")
    var n_nonempty = 0
    for b in range(dir.capacity()):
        if Int(dir.read_slot_at(b)) != Int(SLOT_EMPTY):
            n_nonempty += 1
    assert_equal(
        n_nonempty,
        0,
        (
            "a bucket of the DOUBLED directory is not empty — the fill"
            " loop in reset_doubled did not run"
        ),
    )

    # THE REHASH ROUND-TRIP. A directory that merely LOOKS clear is not
    # enough; every key must be findable at its own slot afterwards, which is
    # what `_rehash_directory` relies on.
    for i in range(n):
        _ = dir.insert_raw(hashes[i], Int32(i))
    for i in range(n):
        var bucket = dir.bucket_of(hashes[i])
        var found = -1
        while True:
            var sl = Int(dir.read_slot_at(bucket))
            if sl == Int(SLOT_EMPTY):
                break
            if sl == i:
                found = i
                break
            bucket = dir.next_bucket(bucket)
        assert_equal(
            found,
            i,
            (
                "a key re-inserted after reset_doubled is not reachable on its"
                " own probe chain"
            ),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
