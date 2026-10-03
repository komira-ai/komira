# =============================================================================
# test_file_discovery.mojo
# =============================================================================
# Unit tests for `FileDiscovery` trait + `EagerGlobDiscovery` impl.
#
# What is testable NOW vs gated separately:
#   * The FILTERING logic (brace-expand -> per-pattern
#     glob_match_path -> dedupe -> lexical sort) is exercised via the injected
#     `filter_paths` seam — this is the pure mode-logic, FS-independent.
#   * `open_paths` (explicit list, order preserved) + the trait accessors
#     (num_paths / path_at / is_lazy / partition hooks) are fully testable.
#   * SINGLE-FILE `open[FS]` mode against a real LocalFs literal path
#     (`is_dir==False`, no `fs.list` needed) is testable.
#   * GLOB / DIRECTORY `open[FS]` against an empty listing: the empty-match
#     RAISE is what we assert for the dir/glob `open` path, and the precise
#     filtering is covered by `filter_paths` against an injected candidate
#     list. End-to-end local discovery is covered by
#     test_local_fs_list_recursive.
#
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_fs.file_discovery import (
    EagerGlobDiscovery,
    FileDiscovery,
    GlobDiscoveryOptions,
    PartitionValues,
    PartitionSchema,
)
from komira_async.ops.waker_sink import NoopSink


# =============================================================================
# Helpers
# =============================================================================


def _candidate_listing() -> List[String]:
    """A synthetic `fs.list` result (as if the static prefix `data/` was
    listed). Deliberately UNSORTED to exercise the lexical sort, and mixes
    `.parquet` / `.csv` + a deeper nested path to exercise `*`-no-cross-slash
    and `**` semantics."""
    var p = List[String]()
    p.append(String("data/year=2025/month=01/c.parquet"))
    p.append(String("data/year=2024/month=02/b.parquet"))
    p.append(String("data/year=2024/month=01/a.parquet"))
    p.append(String("data/year=2024/month=01/a.csv"))  # non-parquet
    p.append(String("data/readme.txt"))  # shallow, no key= dirs
    return p^


# =============================================================================
# open_paths (explicit list) + trait accessors
# =============================================================================


def test_open_paths_preserves_order() raises:
    """open_paths preserves CALLER order."""
    var p = List[String]()
    p.append(String("/z/last.parquet"))
    p.append(String("/a/first.parquet"))
    var disc = EagerGlobDiscovery.open_paths(p)
    assert_equal(disc.num_paths(), 2)
    # Order preserved (NOT lexically sorted): caller's [z, a] stays [z, a].
    assert_equal(disc.path_at(0), String("/z/last.parquet"))
    assert_equal(disc.path_at(1), String("/a/first.parquet"))


def test_open_paths_empty() raises:
    """open_paths([]) yields num_paths == 0 (no raise — the empty-match policy
    applies to glob/dir discovery, not the explicit-list ctor)."""
    var disc = EagerGlobDiscovery.open_paths(List[String]())
    assert_equal(disc.num_paths(), 0)


def test_is_lazy_is_false() raises:
    """EagerGlobDiscovery is EAGER — is_lazy() is a comptime-False static."""
    assert_false(EagerGlobDiscovery.is_lazy())


def test_partition_hooks_empty() raises:
    """EagerGlobDiscovery is NOT partition-aware: partition_values_at and
    partition_schema return EMPTY."""
    var p = List[String]()
    p.append(String("data/year=2024/a.parquet"))
    var disc = EagerGlobDiscovery.open_paths(p)
    var pv = disc.partition_values_at(0)
    assert_equal(pv.num_pairs(), 0)
    var ps = disc.partition_schema()
    assert_equal(ps.num_columns(), 0)


# =============================================================================
# filter_paths — the GLOB mode-logic seam (FS-independent, testable NOW)
# =============================================================================


def test_filter_paths_hive_glob() raises:
    """`data/year=*/month=*/*.parquet` keeps the 3 parquet leaves, drops the
    .csv and the shallow readme.txt; result is LEXICALLY SORTED."""
    var matched = EagerGlobDiscovery.filter_paths(
        _candidate_listing(), String("data/year=*/month=*/*.parquet")
    )
    assert_equal(len(matched), 3)
    # Lexical order: 2024/01 < 2024/02 < 2025/01.
    assert_equal(matched[0], String("data/year=2024/month=01/a.parquet"))
    assert_equal(matched[1], String("data/year=2024/month=02/b.parquet"))
    assert_equal(matched[2], String("data/year=2025/month=01/c.parquet"))


def test_filter_paths_star_no_cross_slash() raises:
    """A single `*` segment does NOT cross `/`: `data/*.txt` matches the
    shallow `data/readme.txt` but NOT any deeper path."""
    var matched = EagerGlobDiscovery.filter_paths(
        _candidate_listing(), String("data/*.txt")
    )
    assert_equal(len(matched), 1)
    assert_equal(matched[0], String("data/readme.txt"))


def test_filter_paths_globstar_recursive() raises:
    """`data/**/*.parquet` — `**` spans zero-or-more segments, so all three
    nested parquet leaves match regardless of depth."""
    var matched = EagerGlobDiscovery.filter_paths(
        _candidate_listing(), String("data/**/*.parquet")
    )
    assert_equal(len(matched), 3)


def test_filter_paths_brace_expansion_union() raises:
    """`{a,b}.parquet` brace-expands to two patterns; the union matches both
    leaves named a/b and DEDUPES any overlap. Here `data/year=2024/month=01/{a}.parquet`
    plus `.../{b}` — but the leaves live under different month dirs, so we use
    a brace over the file stem at a fixed dir to keep it deterministic."""
    var cands = List[String]()
    cands.append(String("d/a.parquet"))
    cands.append(String("d/b.parquet"))
    cands.append(String("d/c.parquet"))
    var matched = EagerGlobDiscovery.filter_paths(
        cands^, String("d/{a,b}.parquet")
    )
    assert_equal(len(matched), 2)
    assert_equal(matched[0], String("d/a.parquet"))
    assert_equal(matched[1], String("d/b.parquet"))


def test_filter_paths_dedupes_overlapping_braces() raises:
    """Overlapping brace alternatives must DEDUPE: `{a,*}`
    expands to `a` and `*`, both of which match `a.parquet` — the union must
    contain it exactly once."""
    var cands = List[String]()
    cands.append(String("a.parquet"))
    cands.append(String("b.parquet"))
    var matched = EagerGlobDiscovery.filter_paths(
        cands^, String("{a,*}.parquet")
    )
    # `a` matches only a.parquet; `*` matches both -> union deduped = {a, b}.
    assert_equal(len(matched), 2)
    assert_equal(matched[0], String("a.parquet"))
    assert_equal(matched[1], String("b.parquet"))


def test_filter_paths_no_match_returns_empty() raises:
    """`filter_paths` itself does NOT enforce the empty-match policy (that is
    `open`'s job) — a no-match filter returns an empty list, not a raise."""
    var matched = EagerGlobDiscovery.filter_paths(
        _candidate_listing(), String("nomatch/*.orc")
    )
    assert_equal(len(matched), 0)


# =============================================================================
# open[FS] — SINGLE-FILE mode (testable against a real LocalFs literal path)
# =============================================================================


def test_open_single_file_literal() raises:
    """`open(fs, '/etc/hosts')`: no glob metachar, `is_dir==False` -> SINGLE-
    FILE mode -> a one-element discovery containing the literal path. /etc/hosts
    is a universally-present POSIX file (Linux + macOS)."""
    var fs = LocalFs[NoopSink].new()
    var disc = EagerGlobDiscovery.open(fs, String("/etc/hosts"))
    assert_equal(disc.num_paths(), 1)
    assert_equal(disc.path_at(0), String("/etc/hosts"))


# =============================================================================
# open[FS] — empty-match policy
# =============================================================================
# NOTE: GLOB/DIRECTORY `open` end-to-end is now LIVE post- (LocalFs.list
# does a real recursive walk). The empty-match tests below therefore use a
# freshly-created EMPTY directory on the `/`-disk (NOT /tmp, NOT a populated
# dir) so the empty-listing -> raise/allow path fires legitimately. The
# POPULATED-directory + glob e2e is covered by
# `tests/test_local_fs_list_recursive.mojo`.


def _empty_dir(tag: String) raises -> String:
    """Create a fresh EMPTY directory under the runner's private
    TEST_TMPDIR and return its path."""
    var base = test_tmpdir()
    var pid = external_call["getpid", Int32]()
    var d = base + String("/g2_empty_") + tag + String("_") + String(Int(pid))
    var rm = String("rm -rf '") + d + String("'")
    var rm_l = rm
    _ = external_call["system", Int32](rm_l.as_c_string_slice().unsafe_ptr())
    var mk = String("mkdir -p '") + d + String("'")
    var mk_l = mk
    var rc = external_call["system", Int32](
        mk_l.as_c_string_slice().unsafe_ptr()
    )
    if Int(rc) != 0:
        raise Error("_empty_dir: mkdir failed for " + d)
    return d


def test_open_directory_empty_raises_by_default() raises:
    """DIRECTORY mode against a real EMPTY directory (post- LocalFs.list
    returns []) -> empty set -> RAISES under the default policy
    (allow_empty_glob=False). The empty dir is_dir==True, so the
    directory branch fires."""
    var d = _empty_dir(String("raise"))
    var fs = LocalFs[NoopSink].new()
    var raised = False
    var msg = String("")
    try:
        _ = EagerGlobDiscovery.open(fs, d)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_true("no files" in msg or "contains no files" in msg)


def test_open_directory_empty_allowed() raises:
    """With allow_empty_glob=True, the empty-directory listing yields an empty
    discovery (num_paths==0) instead of raising."""
    var d = _empty_dir(String("allowed"))
    var fs = LocalFs[NoopSink].new()
    var opts = GlobDiscoveryOptions(allow_empty_glob=True)
    var disc = EagerGlobDiscovery.open_with_options(fs, d, opts)
    assert_equal(disc.num_paths(), 0)


def test_open_glob_empty_raises_by_default() raises:
    """GLOB mode whose static prefix is a real EMPTY directory -> no candidates
    -> empty set -> RAISES with the glob-specific message. This pins
    the mode-DETECTION (has_glob fires) + the raise; the precise filtering is
    covered by `filter_paths` above and the populated e2e by the test."""
    var d = _empty_dir(String("glob"))
    var fs = LocalFs[NoopSink].new()
    var raised = False
    var msg = String("")
    try:
        _ = EagerGlobDiscovery.open(fs, d + String("/*.parquet"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_true("no files matched glob" in msg)


# =============================================================================
# Trait conformance: EagerGlobDiscovery is bindable as a FileDiscovery
# (the comptime trait bound the `DISC` field will use).
# =============================================================================


def _num_paths_via_trait[D: FileDiscovery](disc: D) -> Int:
    """Drives the discovery through the TRAIT bound (not the concrete type) —
    proves EagerGlobDiscovery monomorphizes as a FileDiscovery conformer, the
    exact shape `MultiConsumerSource`'s `Self.DISC` field uses."""
    return disc.num_paths()


def test_binds_as_filediscovery_trait() raises:
    var p = List[String]()
    p.append(String("/x/a.parquet"))
    p.append(String("/x/b.parquet"))
    var disc = EagerGlobDiscovery.open_paths(p)
    assert_equal(_num_paths_via_trait(disc), 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_open_paths_preserves_order]()
    suite.test[test_open_paths_empty]()
    suite.test[test_is_lazy_is_false]()
    suite.test[test_partition_hooks_empty]()
    suite.test[test_filter_paths_hive_glob]()
    suite.test[test_filter_paths_star_no_cross_slash]()
    suite.test[test_filter_paths_globstar_recursive]()
    suite.test[test_filter_paths_brace_expansion_union]()
    suite.test[test_filter_paths_dedupes_overlapping_braces]()
    suite.test[test_filter_paths_no_match_returns_empty]()
    suite.test[test_open_single_file_literal]()
    suite.test[test_open_directory_empty_raises_by_default]()
    suite.test[test_open_directory_empty_allowed]()
    suite.test[test_open_glob_empty_raises_by_default]()
    suite.test[test_binds_as_filediscovery_trait]()
    suite^.run()
