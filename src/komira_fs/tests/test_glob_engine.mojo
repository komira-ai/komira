# =============================================================================
# test_glob_engine.mojo
# =============================================================================
# Exhaustive unit tests for the pure glob pattern-matching engine
# (`komira_fs.glob`).
#
# Test matrix:
#   * has_glob — literal vs glob vs brace-only; `=` (Hive) is NOT a metachar.
#   * brace_expand — single / multiple (cartesian) / nested / none / empty alt.
#   * split_static_prefix — no-glob, glob in seg 0, glob mid-path, `**`.
#   * glob_match_path POSIX (via libc fnmatch) — `*`, `?`, `[a-z]` ranges,
#     `[!abc]` negation, `[[:digit:]]` POSIX classes.
#   * glob_match_path `**` globstar — zero / one / many levels; reject double-`**`.
#   * Edge — empty pattern, trailing `/`, `*.parquet` extension, Hive `=` paths.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_fs.glob import (
    has_glob,
    brace_expand,
    split_static_prefix,
    glob_match_path,
)


# =============================================================================
# has_glob
# =============================================================================


def test_has_glob_literal() raises:
    assert_false(has_glob(String("data/file.parquet")))
    assert_false(has_glob(String("")))
    assert_false(has_glob(String("a/b/c")))


def test_has_glob_metachars() raises:
    assert_true(has_glob(String("*.parquet")))
    assert_true(has_glob(String("data/year=*/x")))
    assert_true(has_glob(String("file?.parquet")))
    assert_true(has_glob(String("part-[0-9].parquet")))
    assert_true(has_glob(String("{a,b}/x")))


def test_has_glob_hive_equals_not_metachar() raises:
    """`=` in a Hive partition segment is NOT a glob metachar — a literal
    Hive path must report has_glob == False."""
    assert_false(has_glob(String("events/dt=2026-11-04/hour=01/part-0.parquet")))


# =============================================================================
# brace_expand
# =============================================================================


def _contains(lst: List[String], want: String) -> Bool:
    for i in range(len(lst)):
        if lst[i] == want:
            return True
    return False


def test_brace_expand_none() raises:
    var out = brace_expand(String("data/part.parquet"))
    assert_equal(len(out), 1)
    assert_equal(out[0], String("data/part.parquet"))


def test_brace_expand_single() raises:
    var out = brace_expand(String("x/{a,b}/y"))
    assert_equal(len(out), 2)
    assert_true(_contains(out, String("x/a/y")))
    assert_true(_contains(out, String("x/b/y")))


def test_brace_expand_three() raises:
    var out = brace_expand(String("{a,b,c}"))
    assert_equal(len(out), 3)
    assert_true(_contains(out, String("a")))
    assert_true(_contains(out, String("b")))
    assert_true(_contains(out, String("c")))


def test_brace_expand_cartesian() raises:
    """Multiple brace groups expand to the cartesian product."""
    var out = brace_expand(String("{a,b}/{c,d}"))
    assert_equal(len(out), 4)
    assert_true(_contains(out, String("a/c")))
    assert_true(_contains(out, String("a/d")))
    assert_true(_contains(out, String("b/c")))
    assert_true(_contains(out, String("b/d")))


def test_brace_expand_nested() raises:
    """A nested brace group expands correctly: {a,{b,c}} -> a, b, c."""
    var out = brace_expand(String("x/{a,{b,c}}/y"))
    assert_equal(len(out), 3)
    assert_true(_contains(out, String("x/a/y")))
    assert_true(_contains(out, String("x/b/y")))
    assert_true(_contains(out, String("x/c/y")))


def test_brace_expand_realistic() raises:
    """Realistic multi-format brace: {parquet,csv} extension alternation."""
    var out = brace_expand(String("data/file.{parquet,csv}"))
    assert_equal(len(out), 2)
    assert_true(_contains(out, String("data/file.parquet")))
    assert_true(_contains(out, String("data/file.csv")))


# =============================================================================
# split_static_prefix
# =============================================================================


def test_split_prefix_no_glob() raises:
    """No glob -> whole path is the prefix, empty residual."""
    var sp = split_static_prefix(String("data/file.parquet"))
    assert_equal(sp[0], String("data/file.parquet"))
    assert_equal(sp[1], String(""))


def test_split_prefix_glob_first_segment() raises:
    """Glob in the first segment -> empty prefix, whole pattern residual."""
    var sp = split_static_prefix(String("*.parquet"))
    assert_equal(sp[0], String(""))
    assert_equal(sp[1], String("*.parquet"))


def test_split_prefix_glob_mid_path() raises:
    """Glob mid-path -> static leading prefix up to the glob segment."""
    var sp = split_static_prefix(String("data/year=*/part-*.parquet"))
    assert_equal(sp[0], String("data/"))
    assert_equal(sp[1], String("year=*/part-*.parquet"))


def test_split_prefix_deep_static() raises:
    var sp = split_static_prefix(String("a/b/c/*.parquet"))
    assert_equal(sp[0], String("a/b/c/"))
    assert_equal(sp[1], String("*.parquet"))


def test_split_prefix_globstar() raises:
    """`**` is a glob metachar (`*`) -> the segment containing it bounds the
    static prefix."""
    var sp = split_static_prefix(String("events/**/data.parquet"))
    assert_equal(sp[0], String("events/"))
    assert_equal(sp[1], String("**/data.parquet"))


def test_split_prefix_hive_static_then_glob() raises:
    """Static Hive prefix preserved up to the first glob segment."""
    var sp = split_static_prefix(
        String("warehouse/events/dt=2026-11-04/*.parquet")
    )
    assert_equal(sp[0], String("warehouse/events/dt=2026-11-04/"))
    assert_equal(sp[1], String("*.parquet"))


# =============================================================================
# glob_match_path — POSIX (via libc fnmatch)
# =============================================================================


def test_match_star_within_segment() raises:
    assert_true(glob_match_path(String("*.parquet"), String("file.parquet")))
    assert_true(
        glob_match_path(String("part-*.parquet"), String("part-0.parquet"))
    )
    assert_false(
        glob_match_path(String("*.parquet"), String("file.csv"))
    )


def test_match_star_does_not_cross_segment() raises:
    """A `*` matches WITHIN one segment only — `*.parquet` must NOT match a
    multi-segment path (segment counts differ)."""
    assert_false(
        glob_match_path(String("*.parquet"), String("dir/file.parquet"))
    )


def test_match_question_mark() raises:
    assert_true(glob_match_path(String("file?.parquet"), String("file1.parquet")))
    assert_true(glob_match_path(String("part-?.csv"), String("part-9.csv")))
    assert_false(
        glob_match_path(String("file?.parquet"), String("file12.parquet"))
    )


def test_match_char_range() raises:
    assert_true(
        glob_match_path(String("part-[0-9].parquet"), String("part-5.parquet"))
    )
    assert_false(
        glob_match_path(String("part-[0-9].parquet"), String("part-x.parquet"))
    )
    assert_true(
        glob_match_path(String("[a-z]*.parquet"), String("table.parquet"))
    )


def test_match_negated_class() raises:
    """`[!...]` negation (POSIX, via fnmatch)."""
    assert_true(
        glob_match_path(String("part-[!0-9].parquet"), String("part-x.parquet"))
    )
    assert_false(
        glob_match_path(String("part-[!0-9].parquet"), String("part-5.parquet"))
    )


def test_match_posix_class_digit() raises:
    """`[[:digit:]]` POSIX character class — proves libc fnmatch is doing the
    per-segment match (we did NOT reimplement classes)."""
    assert_true(
        glob_match_path(
            String("part-[[:digit:]].parquet"), String("part-7.parquet")
        )
    )
    assert_false(
        glob_match_path(
            String("part-[[:digit:]].parquet"), String("part-a.parquet")
        )
    )


def test_match_posix_class_alpha() raises:
    assert_true(
        glob_match_path(
            String("[[:alpha:]]*.parquet"), String("events.parquet")
        )
    )
    assert_false(
        glob_match_path(
            String("[[:alpha:]]*.parquet"), String("9events.parquet")
        )
    )


def test_match_multi_segment_exact() raises:
    """Segment-by-segment match across a multi-segment path."""
    assert_true(
        glob_match_path(
            String("data/year=*/part-*.parquet"),
            String("data/year=2026/part-0.parquet"),
        )
    )
    assert_false(
        glob_match_path(
            String("data/year=*/part-*.parquet"),
            String("data/year=2026/extra/part-0.parquet"),
        )
    )


# =============================================================================
# glob_match_path — `**` globstar
# =============================================================================


def test_globstar_zero_levels() raises:
    """`dir/**/x` matches `dir/x` (zero intermediate segments)."""
    assert_true(
        glob_match_path(String("dir/**/x.parquet"), String("dir/x.parquet"))
    )


def test_globstar_one_level() raises:
    assert_true(
        glob_match_path(
            String("dir/**/x.parquet"), String("dir/a/x.parquet")
        )
    )


def test_globstar_many_levels() raises:
    assert_true(
        glob_match_path(
            String("dir/**/x.parquet"), String("dir/a/b/c/x.parquet")
        )
    )


def test_globstar_with_pattern_tail() raises:
    """`**` followed by a glob segment tail."""
    assert_true(
        glob_match_path(
            String("events/**/*.parquet"),
            String("events/dt=2026/hour=01/part-0.parquet"),
        )
    )
    assert_true(
        glob_match_path(
            String("events/**/*.parquet"), String("events/part-0.parquet")
        )
    )
    assert_false(
        glob_match_path(
            String("events/**/*.parquet"),
            String("other/dt=2026/part-0.parquet"),
        )
    )


def test_globstar_leading() raises:
    """A leading `**` matches any depth prefix."""
    assert_true(
        glob_match_path(String("**/x.parquet"), String("x.parquet"))
    )
    assert_true(
        glob_match_path(String("**/x.parquet"), String("a/b/x.parquet"))
    )


def test_globstar_reject_double() raises:
    """More than one `**` per pattern RAISES (DuckDB HasMultipleCrawl rule)."""
    with assert_raises():
        _ = glob_match_path(
            String("a/**/b/**/c.parquet"), String("a/x/b/y/c.parquet")
        )


# =============================================================================
# Edge cases
# =============================================================================


def test_edge_empty_pattern() raises:
    """Empty pattern matches only the empty path."""
    assert_true(glob_match_path(String(""), String("")))
    assert_false(glob_match_path(String(""), String("x")))


def test_edge_trailing_slash() raises:
    """A trailing `/` yields a trailing empty segment on both sides; a
    pattern with a trailing `/` matches a path with a trailing `/`."""
    assert_true(glob_match_path(String("data/*/"), String("data/sub/")))
    # Pattern with trailing slash should NOT match a path without one
    # (segment counts differ: ['data','*',''] vs ['data','sub']).
    assert_false(glob_match_path(String("data/*/"), String("data/sub")))


def test_edge_extension_filter() raises:
    """`*.parquet` extension filter is the common case."""
    assert_true(glob_match_path(String("*.parquet"), String("part-0.parquet")))
    assert_false(glob_match_path(String("*.parquet"), String("part-0.csv")))


def test_edge_hive_equals_literal() raises:
    """`=` in Hive segments is matched literally (NOT a metachar) — a glob
    against a Hive layout works on the segment boundaries."""
    assert_true(
        glob_match_path(
            String("events/dt=*/part-0.parquet"),
            String("events/dt=2026-11-04/part-0.parquet"),
        )
    )
    assert_false(
        glob_match_path(
            String("events/dt=*/part-0.parquet"),
            String("events/region=us/part-0.parquet"),
        )
    )


def test_edge_literal_exact_match() raises:
    """A pattern with no metachars matches exactly (and only) that path."""
    assert_true(
        glob_match_path(
            String("data/file.parquet"), String("data/file.parquet")
        )
    )
    assert_false(
        glob_match_path(
            String("data/file.parquet"), String("data/other.parquet")
        )
    )


def test_edge_brace_then_match_pipeline() raises:
    """The intended pipeline: brace_expand FIRST, then glob_match_path per
    expanded pattern. A `{parquet,csv}` brace expands to two patterns; the
    path matches exactly one."""
    var pats = brace_expand(String("data/*.{parquet,csv}"))
    assert_equal(len(pats), 2)
    var path = String("data/part-0.parquet")
    var any_match = False
    for i in range(len(pats)):
        if glob_match_path(pats[i], path):
            any_match = True
    assert_true(any_match)


def main() raises:
    # has_glob
    test_has_glob_literal()
    test_has_glob_metachars()
    test_has_glob_hive_equals_not_metachar()
    # brace_expand
    test_brace_expand_none()
    test_brace_expand_single()
    test_brace_expand_three()
    test_brace_expand_cartesian()
    test_brace_expand_nested()
    test_brace_expand_realistic()
    # split_static_prefix
    test_split_prefix_no_glob()
    test_split_prefix_glob_first_segment()
    test_split_prefix_glob_mid_path()
    test_split_prefix_deep_static()
    test_split_prefix_globstar()
    test_split_prefix_hive_static_then_glob()
    # glob_match_path POSIX
    test_match_star_within_segment()
    test_match_star_does_not_cross_segment()
    test_match_question_mark()
    test_match_char_range()
    test_match_negated_class()
    test_match_posix_class_digit()
    test_match_posix_class_alpha()
    test_match_multi_segment_exact()
    # globstar
    test_globstar_zero_levels()
    test_globstar_one_level()
    test_globstar_many_levels()
    test_globstar_with_pattern_tail()
    test_globstar_leading()
    test_globstar_reject_double()
    # edges
    test_edge_empty_pattern()
    test_edge_trailing_slash()
    test_edge_extension_filter()
    test_edge_hive_equals_literal()
    test_edge_literal_exact_match()
    test_edge_brace_then_match_pipeline()
    print("test_glob_engine.mojo PASS (fnmatch FFI + ** + braces)")
