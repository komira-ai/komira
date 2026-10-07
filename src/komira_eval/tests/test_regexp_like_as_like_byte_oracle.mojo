# =============================================================================
# Byte-oracle: routing an `EXPR_REGEXP` `lit.*lit` program to the SQL LIKE
# kernel === the Pike VM, bit-for-bit, plus the RECOGNISER's exact scope.
# =============================================================================
#
# WHAT IS GUARDED. `eval_regexp_like` now recognises the program shape
# `SAVE0 (CHAR)+ ( .* (CHAR)+ )* SAVE1 MATCH` and hands it to
# `eval_string_like` as the equivalent `%seg1%seg2%` pattern, because a
# dataframe front end with no LIKE verb spells `LIKE '%a%b%'` as
# `.str.contains("a.*b")` (an `EXPR_REGEXP`) while SQL emits
# `EXPR_STRING_OP` / `STR_LIKE`. One question, two kernels, and only the LIKE
# kernel has the `%lit%lit%` memmem decomposition.
#
# ⚠ THIS IS THE FALSIFIER FOR THE RECOGNISER, NOT FOR THE MATCHER. No new
# matcher was written — the fast arm IS `eval_string_like`, which carries its
# own byte oracle (`test_string_like_fastpath_byte_oracle.mojo`). What can go
# wrong here is the RECOGNISER admitting a program whose LIKE translation says
# something else, so §2 diffs the two arms over a corpus chosen to make each
# refusal reachable, and §1 pins the accepted/refused classification directly.
#
# HOW THE REFERENCE ARM IS REACHED: the same shape `eval_string_like` already
# uses — a plain defaulted parameter, `use_like_fastpath=False`, which forces
# every row through the Pike VM. No env mutation, so this test is safe to run
# concurrently. Production never passes the argument.
#
# Widening `regexp_like_as_like_pattern` by ONE refusal must
# turn §2 red.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.string_array import StringArray
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.regexp_nfa import RegexProgram
from komira_column_kernels.regexp_functions import (
    eval_regexp_like,
    regexp_like_as_like_pattern,
)


# -----------------------------------------------------------------------------
# §0  helpers
# -----------------------------------------------------------------------------


def _corpus() -> List[String]:
    """Subjects chosen so every accepted pattern below discriminates — some
    rows match and some do not — and so the ORDER requirement is exercised
    (`requests special` must NOT match `%special%requests%`)."""
    var v: List[String] = [
        String(""),
        String("a"),
        String("ab"),
        String("ba"),
        String("special"),
        String("requests"),
        String("special requests"),
        String("requests special"),
        String("specialrequests"),
        String("xspecialyrequestsz"),
        String("this order has special requests attached"),
        String("no anomalies here at all"),
        String("special but no r-word"),
        String("SPECIAL REQUESTS"),
        String("special special requests requests"),
        String("Customer Complaints"),
        String("Complaints Customer"),
        String("the Customer had Complaints"),
        # Newline subjects: `%` crosses one, a non-DOTALL `.` does not. These
        # are the ONLY rows that discriminate the DOTALL refusal, so each
        # accepted pattern's segment letters must appear ACROSS the newline —
        # `a\nb` for `a.*b`, `special\nrequests` for the q13 shape. Without
        # them §2 stays GREEN when the DOTALL check is mutated out while only
        # §1 goes red: a falsifier that does not falsify.
        String("special\nrequests"),
        String("line1\nline2"),
        String("a\nb"),
        String("xax\nxbx"),
        String("Customer\nComplaints"),
        # literal LIKE metacharacters in the SUBJECT (never wildcards there).
        String("100%special%requests"),
        String("a_c"),
        String("percent % here"),
        # REGEX metacharacters that are LITERAL bytes in a LIKE pattern. Each
        # is paired with the near-miss `axb`, which the escaped regex must NOT
        # match and which a mis-lowering into a wildcard WOULD match.
        String("a*b"),
        String("a+b"),
        String("a[b"),
        String("a\\b"),
        String("axb"),
        String("a.b"),
        # non-ASCII, to pin that a segment is assembled byte-exactly.
        String("café special requests"),
        String("ééé"),
    ]
    return v^


def _assert_fast_equals_vm(pattern: String, flags: String) raises:
    """Both arms of `eval_regexp_like` over `_corpus()`, all-valid."""
    var arr = StringArray.from_strings(_corpus())
    var prog = RegexProgram.compile(pattern, flags)

    var vm = eval_regexp_like(arr, prog, use_like_fastpath=False)
    var fast = eval_regexp_like(arr, prog)  # default == production

    assert_equal(vm.length, fast.length, "length mismatch for /" + pattern + "/")
    assert_equal(
        vm.null_count,
        fast.null_count,
        "null_count mismatch for /" + pattern + "/",
    )
    var values = _corpus()
    for i in range(vm.length):
        assert_equal(
            vm.is_null(i),
            fast.is_null(i),
            "validity divergence /" + pattern + "/ row " + String(i),
        )
        if not vm.is_null(i):
            assert_equal(
                vm.get(i),
                fast.get(i),
                "byte divergence /" + pattern + "/ row " + String(i)
                + " value='" + values[i] + "'",
            )


def _assert_fast_equals_vm_nullable(pattern: String, flags: String) raises:
    """The same diff over a NULLABLE column.

    This is the arm that catches the one real semantic gap in the delegation:
    `eval_string_like` returns a bare mask with NO validity, while
    `eval_regexp_like` propagates NULL -> NULL."""
    var values = _corpus()
    var valid = List[Bool]()
    for i in range(len(values)):
        # Every third row NULL, so a null lands on both matching and
        # non-matching content for each pattern below.
        valid.append(i % 3 != 0)
    var arr = StringArray.from_strings_with_validity(values, valid)
    var prog = RegexProgram.compile(pattern, flags)

    var vm = eval_regexp_like(arr, prog, use_like_fastpath=False)
    var fast = eval_regexp_like(arr, prog)

    assert_equal(
        vm.length, fast.length, "nullable length mismatch /" + pattern + "/"
    )
    assert_equal(
        vm.null_count,
        fast.null_count,
        "nullable null_count mismatch /" + pattern + "/",
    )
    for i in range(vm.length):
        assert_equal(
            vm.is_null(i),
            fast.is_null(i),
            "nullable validity divergence /" + pattern + "/ row " + String(i),
        )
        # ⚠ UNCONDITIONAL — the bit under a NULL is compared too
        # (`BooleanArray.get` reads `data.test` and never consults validity).
        # ⛔ THIS ARM CANNOT FALSIFY `res.data.clear(i)` AND MUST NOT BE CITED
        # AS IF IT DID: `from_strings_with_validity` gives every NULL row a
        # ZERO-LENGTH slot, so the LIKE kernel reads an empty string there and
        # its bit is 0 whatever the pattern. The falsifier for the clear is
        # `test_null_row_with_live_backing_bytes` below, which builds the
        # array Arrow actually permits. Kept here so a future change to the
        # helper's null-slot policy is caught rather than silently widening.
        assert_equal(
            vm.get(i),
            fast.get(i),
            "nullable byte divergence /" + pattern + "/ row " + String(i)
            + " (is_null=" + String(vm.is_null(i)) + ")",
        )


def _accepted_as(pattern: String, flags: String, expect: String) raises:
    var prog = RegexProgram.compile(pattern, flags)
    var got = regexp_like_as_like_pattern(prog)
    assert_true(
        Bool(got), "/" + pattern + "/ flags='" + flags + "' should be ACCEPTED"
    )
    assert_equal(
        got.value(),
        expect,
        "/" + pattern + "/ flags='" + flags + "' lowered wrong",
    )


def _refused(pattern: String, flags: String) raises:
    var prog = RegexProgram.compile(pattern, flags)
    var got = regexp_like_as_like_pattern(prog)
    assert_false(
        Bool(got), "/" + pattern + "/ flags='" + flags + "' should be REFUSED"
    )


# -----------------------------------------------------------------------------
# §1  the RECOGNISER's scope, stated as a classification
# -----------------------------------------------------------------------------


def test_accepts_the_two_corpus_patterns() raises:
    """The exact regex programs a dataframe front end emits for the LIKE
    filters of TPC-H q13 and q16."""
    _accepted_as(
        String("(?s)special.*requests"), String(""), String("%special%requests%")
    )
    _accepted_as(
        String("(?s)Customer.*Complaints"),
        String(""),
        String("%Customer%Complaints%"),
    )


def test_accepts_the_shape_family() raises:
    _accepted_as(String("(?s)abc"), String(""), String("%abc%"))
    _accepted_as(String("(?s)a.*b.*c"), String(""), String("%a%b%c%"))
    # `s` passed as a FLAG rather than inline — same program.
    _accepted_as(String("a.*b"), String("s"), String("%a%b%"))
    # Lazy `.*?`: greediness picks WHICH match, not WHETHER one exists, and
    # `is_match` returns only `.matched`.
    _accepted_as(String("(?s)a.*?b"), String(""), String("%a%b%"))
    # A leading/trailing `.*` is redundant under an unanchored search and
    # collapses into the bookend `%` rather than producing an empty segment.
    _accepted_as(String("(?s).*a.*"), String(""), String("%a%"))
    _accepted_as(String("(?s)a.*.*b"), String(""), String("%a%b%"))
    # An ESCAPED metacharacter is a literal byte and belongs in the segment.
    # `.` `*` `+` `[` are regex metacharacters and LITERAL bytes in a LIKE
    # pattern, so each must survive the lowering unescaped and unaltered; a
    # backslash is literal on BOTH sides (`_like_match` has no escape
    # mechanism at all -- only `%` and `_` are metacharacters there, which is
    # exactly why those two are the segment refusal).
    _accepted_as(String("(?s)a\\.c"), String(""), String("%a.c%"))
    _accepted_as(String("(?s)a\\*b"), String(""), String("%a*b%"))
    _accepted_as(String("(?s)a\\+b"), String(""), String("%a+b%"))
    _accepted_as(String("(?s)a\\[b"), String(""), String("%a[b%"))
    _accepted_as(String("(?s)a\\\\b"), String(""), String("%a\\b%"))
    # Non-ASCII: the segment is assembled byte-exactly, so the pattern is the
    # two UTF-8 bytes of `é` and not a re-encoding of codepoint 0xC3.
    _accepted_as(
        String("(?s)café.*x"), String(""), String("%café%x%")
    )


def test_refuses_non_dotall_dot() raises:
    """`.` without DOTALL does not cross a newline; `%` does. THE refusal."""
    _refused(String("a.*b"), String(""))
    _refused(String("(?s)a.*(?-s:c.*d)"), String(""))


def test_refuses_like_metacharacters_in_a_segment() raises:
    """The built LIKE pattern has no escape mechanism, so a `%` or `_` inside a
    segment would become a WILDCARD and return EXTRA rows."""
    _refused(String("(?s)a%b"), String(""))
    _refused(String("(?s)a_b"), String(""))
    _refused(String("(?s)100%.*done"), String(""))


def test_refuses_anchors_classes_groups_and_other_quantifiers() raises:
    _refused(String("(?s)^a.*b"), String(""))       # OP_ASSERT
    _refused(String("(?s)a.*b$"), String(""))       # OP_ASSERT
    _refused(String("(?s)a.+b"), String(""))        # `.+` needs >= 1 byte
    _refused(String("(?s)a.?b"), String(""))        # `.?` is bounded
    _refused(String("(?s)a.b"), String(""))         # a BARE `.` is one byte
    _refused(String("(?s)a[0-9]*b"), String(""))    # OP_CLASS
    _refused(String("(?s)(a).*b"), String(""))      # capturing group
    _refused(String("(?s)a|b"), String(""))         # alternation
    _refused(String("(?s)a.{2,4}b"), String(""))    # bounded repeat
    _refused(String("(?s)(?:ab)*c"), String(""))    # non-`.` star
    _refused(String("(?is)a.*b"), String(""))     # case-insensitive
    _refused(String("(?s)a.*b"), String("i"))


def test_refuses_zero_segment_programs() raises:
    """`(?s).*` and the empty pattern match every non-NULL row. The VM already
    says so; nothing in the corpus asks it, so it is not reasoned about here."""
    _refused(String("(?s).*"), String(""))
    _refused(String(""), String(""))


# -----------------------------------------------------------------------------
# §2  the byte oracle — fast arm === Pike VM
# -----------------------------------------------------------------------------


def _oracle_patterns() -> List[String]:
    var p: List[String] = [
        # ACCEPTED shapes (these are what the routing changes).
        String("(?s)special.*requests"),
        String("(?s)Customer.*Complaints"),
        String("(?s)a.*b"),
        String("(?s)a.*b.*c"),
        String("(?s)abc"),
        String("(?s)a"),
        String("(?s)a.*?b"),
        String("(?s).*a.*"),
        String("(?s)a.*.*b"),
        String("(?s)a\\.c"),
        String("(?s)a\\*b"),
        String("(?s)a\\+b"),
        String("(?s)a\\[b"),
        String("(?s)a\\\\b"),
        String("(?s)café.*x"),
        String("(?s)special"),
        String("(?s)l.*e"),
        # REFUSED shapes: both arms run the VM, so toggling must be a no-op.
        # The first three are the DOTALL discriminators — their segments span
        # a newline in `_corpus()`, so admitting them would diverge.
        String("a.*b"),
        String("special.*requests"),
        String("Customer.*Complaints"),
        String("(?s)a%b"),
        String("(?s)a_b"),
        String("(?s)^special.*requests"),
        String("(?s)special.*requests$"),
        String("(?s)a.+b"),
        String("(?s)a.b"),
        String("(?s)a[0-9]*b"),
        String("(?s)(a).*b"),
        String("(?s)special|requests"),
        String("(?s).*"),
        String(""),
    ]
    return p^


def test_byte_oracle_all_valid() raises:
    var pats = _oracle_patterns()
    for i in range(len(pats)):
        _assert_fast_equals_vm(pats[i], String(""))


def test_byte_oracle_nullable() raises:
    var pats = _oracle_patterns()
    for i in range(len(pats)):
        _assert_fast_equals_vm_nullable(pats[i], String(""))


def test_null_row_with_live_backing_bytes() raises:
    """`res.data.clear(i)`, made falsifiable — the bit UNDER a null.

    ⚠ WHY THE TWO NULLABLE ARMS ABOVE DO NOT COVER THIS.
    `from_strings_with_validity` gives every NULL row an `(offset, length=0)`
    slot, so `eval_string_like` reads an EMPTY string there and its bit is 0
    for every accepted pattern — the clear is a no-op on that shape, and
    deleting `res.data.clear(i)` would leave the other tests GREEN.

    Arrow does not promise an empty slice under a NULL, and
    `_regexp_like_via_like_kernel`'s own comment rests on exactly that ("the
    LIKE kernel may legitimately have matched garbage there"). So this builds
    the array that comment describes and no helper produces: real offsets,
    real bytes, validity cleared on top. It is the only shape in which the two
    kernels can disagree about the bit under a null, which makes it the only
    shape that can falsify the line."""
    var values = _corpus()
    var n = len(values)
    var prog = RegexProgram.compile(
        String("(?s)special.*requests"), String("")
    )

    # NON-VACUITY, ASSERTED BEFORE THE DIFF. If no row this marks NULL would
    # have MATCHED, both arms are 0 everywhere and the comparison below proves
    # nothing — the failure mode this whole test exists to correct.
    var probe = eval_regexp_like(StringArray.from_strings(values), prog)
    var discriminating = 0
    for i in range(n):
        if i % 2 == 0 and probe.get(i):
            discriminating += 1
    assert_true(
        discriminating > 0,
        "VACUOUS: no NULL-marked row would have matched the pattern",
    )

    var arr = StringArray.from_strings(values)
    var vbm = Bitmap.create_all_valid(n)
    var nulls = 0
    for i in range(n):
        if i % 2 == 0:
            vbm.clear(i)
            nulls += 1
    arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
    arr.null_count = nulls

    var vm = eval_regexp_like(arr, prog, use_like_fastpath=False)
    var fast = eval_regexp_like(arr, prog)

    assert_equal(vm.length, fast.length, "live-bytes length mismatch")
    assert_equal(
        vm.null_count, fast.null_count, "live-bytes null_count mismatch"
    )
    for i in range(n):
        assert_equal(
            vm.is_null(i),
            fast.is_null(i),
            "live-bytes validity divergence row " + String(i),
        )
        assert_equal(
            vm.get(i),
            fast.get(i),
            "live-bytes RAW BIT divergence row " + String(i)
            + " (is_null=" + String(vm.is_null(i)) + ")",
        )


# -----------------------------------------------------------------------------
# §3  hand-computed truth — so fast and VM agreeing on a SHARED bug is caught
# -----------------------------------------------------------------------------


def test_q13_semantics_pinned_against_hand_truth() raises:
    """`%special%requests%` — the ORDER requirement is the interesting half."""
    var values: List[String] = [
        String("special requests"),           # T
        String("requests special"),           # F — wrong order
        String("specialrequests"),            # T — adjacent
        String("special"),                    # F — second segment missing
        String("requests"),                   # F — first segment missing
        String("xspecialyrequestsz"),         # T — both, in order, embedded
        String("SPECIAL REQUESTS"),           # F — LIKE is case-sensitive
        String(""),                           # F
        String("special\nrequests"),          # T — `%`/DOTALL crosses \n
        String("special special requests"),   # T
        String("requests special requests"),  # T — a later pair matches
    ]
    var expect: List[Bool] = [
        True, False, True, False, False, True, False, False, True, True, True,
    ]
    var arr = StringArray.from_strings(values)
    var prog = RegexProgram.compile(String("(?s)special.*requests"), String(""))
    var fast = eval_regexp_like(arr, prog)
    var vm = eval_regexp_like(arr, prog, use_like_fastpath=False)
    for i in range(len(values)):
        assert_equal(
            fast.get(i), expect[i], "fast arm row " + String(i) + " truth"
        )
        assert_equal(
            vm.get(i), expect[i], "VM arm row " + String(i) + " truth"
        )


def test_newline_is_the_dotall_discriminator() raises:
    """Without `(?s)` the program is REFUSED, and the VM's answer on a newline
    subject differs from the LIKE kernel's — which is exactly why it is
    refused. Both facts in one test so the refusal cannot be quietly dropped."""
    var values: List[String] = [String("special\nrequests")]
    var arr = StringArray.from_strings(values)

    var no_s = RegexProgram.compile(String("special.*requests"), String(""))
    assert_false(
        Bool(regexp_like_as_like_pattern(no_s)),
        "a non-DOTALL `.` must be refused",
    )
    assert_false(
        eval_regexp_like(arr, no_s).get(0),
        "`.` must NOT cross a newline",
    )

    var with_s = RegexProgram.compile(
        String("(?s)special.*requests"), String("")
    )
    assert_true(
        Bool(regexp_like_as_like_pattern(with_s)), "DOTALL must be accepted"
    )
    assert_true(
        eval_regexp_like(arr, with_s).get(0),
        "`%` (and a DOTALL `.`) MUST cross a newline",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
