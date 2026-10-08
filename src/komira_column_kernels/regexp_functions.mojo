# =============================================================================
# REGEXP — column-level kernels for `regexp_like` / `regexp_matches` /
#          `regexp_extract` and the rest of the `regexp_*` family.
# =============================================================================
#
# These wrap the pure-Mojo Thompson NFA (`regexp_nfa.mojo`) — per-row loops
# over a StringArray, mirroring `string_comparison.mojo`'s `eval_string_*`
# kernels. Rows are read as borrowed `Span`s over the Arrow data buffer
# (`col.get_span(i)`).  NULL handling: a NULL input row -> NULL output
# (the kernels carry the input's validity bitmap through).  A NULL pattern
# is handled by the caller (the
# pattern is a plan-literal; if NULL, the caller returns an all-NULL column
# without compiling).
#
# PERF note: the `RegexProgram` is built once per *call* here (i.e. once per
# batch from the executor's dispatch arm), not once per PLAN. Compiling a
# typical URL-rewriting pattern costs a few microseconds, so even ~800
# recompiles per query cost a few milliseconds against a multi-second
# query. Compile-once-per-plan would be a HYGIENE change, not a performance
# one.
#
# ⭐ THE LEVER THAT IS REAL is one rung up and it is IN THIS FILE: run the
# pattern once per DISTINCT SUBJECT, not once per row.  See `_ReplaceMemo`.
# =============================================================================

from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import Bitmap
from komira_arrow.list_array import ListArray
from komira_arrow.string_builder import ArrowStringBuilder
from komira_column_kernels.regexp_nfa import (
    RegexProgram,
    RegexMatch,
    RegexScratch,
    OP_CHAR,
    OP_ANY,
    OP_MATCH,
    OP_JMP,
    OP_SPLIT,
    OP_SAVE,
)
from komira_column_kernels.string_comparison import eval_string_like
from komira_dynamic_filter.bloom_filter import xxhash64
from komira_simd.byte_class.byte_equal import bytes_equal
from komira_column_kernels.rxcensus import (
    RXCENSUS_ROWS_ENABLED,
    RXC_REPLACE_CALLS,
    RXC_REPLACE_ROWS,
    RXC_MEMO_HITS,
    RXC_MEMO_VM,
    RXC_MEMO_KEYBYTES,
    RXC_MEMO_OFF_CALLS,
    rxcensus_add,
)


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _bytes_to_str(b: List[UInt8], lo: Int, hi: Int) -> String:
    """`b[lo:hi]` as a `String`, BYTE-FAITHFULLY.

    ⛔⛔ NOT A `chr(Int(byte))` LOOP, AND THAT IS WHAT THIS FUNCTION IS FOR.
    `chr(Int(b))` is a CODEPOINT constructor: a byte >= 0x80 comes back as its
    TWO-BYTE UTF-8 encoding, so the string is silently doubled and corrupted.
    This function IS the string builder for every regexp output on this engine
    — `regexp_extract`, `regexp_replace`, `regexp_substr`, `regexp_match`,
    `regexp_split_to_array`, `regexp_extract_all` all route through it — so
    that loop corrupted every non-ASCII result any of them produced.

    Against DuckDB v1.5.3: `regexp_extract('Straße','a(.*)e',1)` is `'ß'`,
    TWO bytes; a `chr` loop answers a FOUR-byte value that renders as
    `Ã\u009f`. A regression test asserts the BYTE COUNT and not just the
    string, because 2-vs-4 says exactly what happened where a string
    comparison only says "different".

    ⚠ THE BYTE RANGE IS NOT VALIDATED, DELIBERATELY. This engine's NFA runs
    over BYTES, so a pattern CAN legally select a span that splits a codepoint;
    a `chr` loop would "handle" that by corrupting every non-ASCII span
    instead. `StringArray.from_byte_lists` — the byte-faithful array builder
    for exactly this trap — has the same property. A split codepoint is a
    wrong PATTERN; a doubled byte would be a wrong ANSWER for every correct one.
    """
    var out = List[UInt8](capacity=hi - lo)
    for j in range(lo, hi):
        out.append(b[j])
    return String(StringSlice(unsafe_from_utf8=Span[UInt8](out)))


def _bytes_to_str(b: Span[UInt8, _], lo: Int, hi: Int) -> String:
    """`b[lo:hi]` as a `String`, BYTE-FAITHFULLY — the `Span` twin of the
    `List` overload above, for the zero-copy row path (`col.get_span(i)`).

    ⛔ SAME RULE, SAME REASON: no `chr(Int(byte))`.  It slices the span (a
    borrow, no copy) and hands the bytes to `StringSlice(unsafe_from_utf8=)`
    exactly as the `List` overload does, so both spellings produce the same
    bytes for the same range.
    """
    return String(StringSlice(unsafe_from_utf8=b[lo:hi]))



def regexp_escape_bytes(s: String) -> List[UInt8]:
    """`regexp_escape(s)` — RE2's `QuoteMeta`, over BYTES.

    ⚠ THE RULE IS NOT "ESCAPE THE METACHARACTERS", IT IS "ESCAPE EVERYTHING
    THAT IS NOT `[A-Za-z0-9_]`", and that was MEASURED rather than assumed:
    running every byte 1..127 through v1.5.3's `regexp_escape` shows a
    backslash in front of ALL of them except the alphanumerics and `_` —
    including space, `/`, `:`, `@`, `-` and the C0 controls, none of which is
    a regex metacharacter. A hand-written metacharacter list would be a strict
    subset and would silently leave, say, a `-` unescaped inside a character
    class the caller then builds.

    ⚠ BYTES >= 0x80 ARE LEFT VERBATIM. MEASURED: `regexp_escape('é.b')` =
    'é\\.b' — the two bytes of `é` pass through untouched, so the byte-wise
    implementation is exact rather than approximate.

    ⭐ IT LIVES HERE, NOT IN `compiler_eval_column`, BECAUSE IT HAS TWO
    CALLERS AND THEY ARE IN DIFFERENT PACKAGES. The kernel side evaluates
    `STRFN_REGEXP_ESCAPE` over a column; the BINDER side (`string_split`)
    escapes a plan-time separator LITERAL so a plain-text split can reuse the
    regexp split. Two copies of a rule that was read off 127 measured bytes is
    two chances for one of them to drift, and the drift would be silent — a
    separator whose `-` stopped being escaped still splits correctly on most
    inputs."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = b[i]
        if (
            (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or (c >= 48 and c <= 57)
            or c == 95
            or c >= 0x80
        ):
            out.append(c)
        else:
            out.append(92)  # backslash
            out.append(c)
    return out^


def regexp_escape_str(s: String) -> String:
    """`regexp_escape_bytes` as a `String`, byte-faithfully.

    ⛔ THE CONVERSION IS `StringSlice(unsafe_from_utf8=...)`, NEVER A
    `chr(Int(byte))` LOOP. `chr` is a CODEPOINT constructor, so a byte >= 0x80
    comes back as its two-byte UTF-8 encoding and every non-ASCII separator is
    silently doubled — the trap `_bytes_to_str` above exists to document."""
    var out = regexp_escape_bytes(s)
    return String(StringSlice(unsafe_from_utf8=Span[UInt8](out)))


def _row_bytes(col: StringArray[HeapRegion], idx: Int) raises -> List[UInt8]:
    """Materialize row `idx` of `col` as a byte list.

    ⚠ USED BY 3 OF 10 KERNELS.  Seven kernels read rows through
    `col.get_span(i)` + a shared `RegexScratch`: `like`, `full_match`,
    `extract`, `substr`, `count`, `instr`, `replace`.  The THREE `ListArray`
    kernels — `eval_regexp_match`, `eval_regexp_split_to_array`,
    `eval_regexp_extract_all` — call this, and build a fresh scratch
    per row inside `find`/`find_all_in`, because each of them slices the
    subject into an owned `List[String]` afterwards anyway.  So:
    * a perf claim about "the regexp kernels" does NOT cover these three;
    * converting them is mechanical (`Span` subject + one hoisted scratch).
    """
    return _str_bytes(col.get(idx))


# =============================================================================
# REGEXP_LIKE -> SQL LIKE: the `lit.*lit` shape, matched by the LIKE kernel
# =============================================================================
#
# ★ ONE QUESTION, TWO SPELLINGS. `o_comment LIKE '%special%requests%'`
# (TPC-H q13) reaches the ENGINE as `EXPR_STRING_OP` / `STR_LIKE` from SQL
# and as `EXPR_REGEXP` / `REGEXP_LIKE` from pandas- or polars-style frontends,
# because neither pandas nor polars has a LIKE verb and both spell *"`a`,
# then later `b`"* as `.str.contains("a.*b")` — at their OWN defaults
# (`regex=True` / `literal=False`). Same data, same answer, and without this
# routing two very different costs: `eval_string_like` decomposes a
# `%`-delimited pattern into memmem substring searches
# (`string_comparison.mojo`), and the Pike VM has no counterpart — it
# allocates a `List[Int]` slot vector per thread per byte position. The gap
# is more than an order of magnitude.
#
# ★ SO THIS DOES NOT ADD A SECOND FAST PATH — IT ROUTES TO THE FIRST ONE.
# A program of this shape is handed to `eval_string_like` as the LIKE pattern
# it is equivalent to, so every spelling converges on ONE kernel, the one
# that carries the `%lit%lit%` byte oracle. No new matcher is written here —
# what is new is the RECOGNISER below, and a byte-oracle test that diffs the
# routing against the Pike VM is its falsifier.
#
# ⚠ WHY THE RECOGNISER READS THE PROGRAM AND NOT THE PATTERN TEXT. The program
# is what executes. `(?s)a.*b`, `(?s:a.*b)`, an inline `(?s)` mid-pattern and
# a `\x2e`-escaped dot all reach the VM as instructions, and a text matcher
# would have to re-implement the parser to tell them apart. Reading `prog.prog`
# means the recogniser cannot disagree with the executor about what the pattern
# says — the class of bug that a second parser exists to create.
#
# THE ACCEPTED SHAPE, and it is the whole shape:
#
#     SAVE 0 ; ( CHAR b )+ ( DOTSTAR ( CHAR b )+ )* ; SAVE 1 ; MATCH
#
# where DOTSTAR is the exact 3-instruction fragment `_compile_node` emits for
# `.*` under DOTALL (see `regexp_nfa.mojo`), at absolute pc `s`:
#
#     s   : SPLIT a=s+1, b=s+3     (greedy)   or  SPLIT a=s+3, b=s+1  (lazy)
#     s+1 : ANY   a=1              (a==1 IS the dotall flag — see below)
#     s+2 : JMP   a=s
#
# EQUIVALENCE, in one line: `is_match` is an UNANCHORED existence test, so a
# program of this shape matches iff the literal segments occur in order
# anywhere in the subject — which is exactly what `LIKE '%seg1%seg2%'` asks,
# and exactly what `_analyze_like_pattern` builds from that pattern (leading
# and trailing `%` => `anchored_start = anchored_end = False`).
#
# ⛔ FIVE REFUSALS, AND EACH ONE HAS A REASON RATHER THAN CAUTION:
#
#   ANY with a != 1   `.` without DOTALL does NOT match a newline and `%` DOES.
#                     The flag is read PER INSTRUCTION,
#                     off `Inst.a`, not off `prog.flags` — `_compile_node`
#                     bakes it in at emit time (see `regexp_nfa.mojo`), so a
#                     scoped `(?s:...)` is read correctly and a scoped
#                     `(?-s:...)` is refused correctly.
#
#   `%` or `_` in a   The LIKE pattern this builds has NO escape mechanism —
#   segment           `_like_match`'s own header records that a backslash is a
#                     literal byte there. A segment byte of `%` or `_` would
#                     become a WILDCARD after the join and silently return
#                     EXTRA rows.
#
#   case_insensitive  Under `i` an ASCII LETTER compiles to OP_CLASS and is
#                     refused by the walker anyway; a non-letter stays OP_CHAR
#                     and WOULD be correct, since the LIKE kernel matches bytes
#                     and `i` is a no-op on it. That is a true statement whose
#                     proof is three steps long, so the flag is refused
#                     outright instead. It costs little: case-insensitive
#                     `a.*b` filters are rare.
#
#   n_groups != 0     A capturing group emits its own SAVE pair, which the
#                     walker refuses. Checked up front so the reason is named
#                     rather than inferred from an opcode.
#
#   zero segments     `(?s).*` and the empty pattern match every non-NULL row.
#                     `_like_plan_match` handles that (nseg == 0 -> True) but
#                     it is rare, so it is left to the VM rather than reasoned
#                     about here.
#
# Everything else falls out of the walker: OP_CLASS (a character class),
# OP_ASSERT (`^`, `$`, `\b` — so every accepted program is fully unanchored,
# which is what makes `anchored_start = anchored_end = False` unconditional),
# a bare `.`, `.+`, `.?`, `{n,m}`, alternation and any nested quantifier all
# reach an opcode or a SPLIT target the walk does not admit, and refuse.
#
# ⚠ LAZY `.*?` IS ADMITTED ON PURPOSE. Greediness picks WHICH match wins, not
# WHETHER one exists, and `is_match` returns only `.matched` — it discards the
# capture slots that could tell the two apart.
# =============================================================================


def regexp_like_as_like_pattern(prog: RegexProgram) -> Optional[String]:
    """The SQL LIKE pattern equivalent to `prog` under `is_match`, or None.

    None means "not this shape" and is never an error: the caller runs the
    Pike VM, which is the reference semantics for every pattern. See the block
    above for the accepted shape and for each refusal's reason."""
    if prog.flags.case_insensitive:
        return None
    if prog.n_groups != 0:
        return None

    var n = len(prog.prog)
    # `RegexProgram.compile` always wraps the body in group 0:
    #   SAVE 0 ; <body> ; SAVE 1 ; MATCH.
    if n < 3:
        return None
    if prog.prog[0].op != OP_SAVE or prog.prog[0].a != 0:
        return None
    if prog.prog[n - 2].op != OP_SAVE or prog.prog[n - 2].a != 1:
        return None
    if prog.prog[n - 1].op != OP_MATCH:
        return None

    # Build `%seg1%seg2%...%` as BYTES. A segment is a contiguous OP_CHAR run
    # and may hold any byte value, so the pattern is assembled byte-exactly and
    # converted once — `chr()` would re-encode a byte >= 0x80 as two UTF-8
    # bytes and silently change the pattern.
    var out = List[UInt8]()
    out.append(UInt8(ord("%")))
    var seg_bytes = 0      # bytes in the segment being accumulated
    var n_segs = 0         # segments closed so far (a `%` is written per close)

    var pc = 1
    var body_end = n - 2   # exclusive: body is [1, n-3]
    while pc < body_end:
        var ins = prog.prog[pc]
        if ins.op == OP_CHAR:
            if ins.a < 0 or ins.a > 255:
                return None
            var b = UInt8(ins.a)
            if b == UInt8(ord("%")) or b == UInt8(ord("_")):
                return None
            out.append(b)
            seg_bytes += 1
            pc += 1
            continue
        # The `.*` gadget, all three instructions inside the body.
        if ins.op == OP_SPLIT and pc + 2 < body_end:
            var greedy = ins.a == pc + 1 and ins.b == pc + 3
            var lazy = ins.a == pc + 3 and ins.b == pc + 1
            var is_dotall_any = (
                prog.prog[pc + 1].op == OP_ANY and prog.prog[pc + 1].a == 1
            )
            var loops_back = (
                prog.prog[pc + 2].op == OP_JMP and prog.prog[pc + 2].a == pc
            )
            if (greedy or lazy) and is_dotall_any and loops_back:
                if seg_bytes > 0:
                    out.append(UInt8(ord("%")))
                    n_segs += 1
                    seg_bytes = 0
                pc += 3
                continue
        return None

    if seg_bytes > 0:
        out.append(UInt8(ord("%")))
        n_segs += 1
    if n_segs == 0:
        return None
    return Optional[String](String(StringSlice(unsafe_from_utf8=Span[UInt8](out))))


# ---------------------------------------------------------------------------
# regexp_like / regexp_matches  ->  BooleanArray
# ---------------------------------------------------------------------------

def _regexp_like_via_like_kernel(
    col: StringArray[HeapRegion], like_pattern: String
) raises -> BooleanArray:
    """`eval_string_like`'s answer, carrying `eval_regexp_like`'s NULL contract.

    ⚠⚠ THE LOOP BELOW IS REDUNDANT FOR ANSWERS, AND SAYING SO IS THE POINT.
    `eval_string_like` ends in `_apply_validity`, which clears the data bit and
    attaches the validity bitmap — exactly what the loop below computes. It is
    a local answer to a question the kernel already answers, and a mechanism no
    assertion can see tends to get simplified away by the next reader.

    ⛔ IT IS RETAINED, AND NOT ON A "TO BE SAFE" ARGUMENT. Deleting it is NOT a
    no-op: the early return keys on `null_count <= 0 or not col.validity` while
    `_apply_validity` keys on the bitmap alone, so a column that HAS a validity
    bitmap and ZERO nulls comes back from the kernel carrying an all-ones
    validity where this function returns a bare mask. That difference is
    invisible in every answer and VISIBLE to `if not left_mask.validity` in
    `_eval_short_circuit_{and,or}`, i.e. removing it is a plan-shape change on
    a zero-null column and needs its own measurement. A byte-oracle test diffs
    this routing against the Pike VM.

    What the loop does: a NULL row's bit is CLEARED and its validity bit
    dropped, which is byte-for-byte what the VM loop below produces (it
    `continue`s on a NULL without ever calling `bm.set`). Clearing is not
    cosmetic — Arrow does not promise an empty slice under a NULL, so a LIKE
    kernel may legitimately have matched garbage there."""
    var res = eval_string_like(col, like_pattern)
    if col.null_count <= 0 or not col.validity:
        return res^
    var n = col.length
    var vbm = Bitmap.create_all_valid(n)
    var nulls_seen = 0
    for i in range(n):
        if col.is_null(i):
            res.data.clear(i)
            vbm.clear(i)
            nulls_seen += 1
    if nulls_seen > 0:
        res.validity = Optional[Bitmap[HeapRegion]](vbm^)
        res.null_count = nulls_seen
    return res^


def eval_regexp_like(
    col: StringArray[HeapRegion],
    prog: RegexProgram,
    use_like_fastpath: Bool = True,
) raises -> BooleanArray:
    """For each row: True iff the string contains a match for `prog`
    (unanchored).  NULL row -> NULL.  Empty pattern matches every row.

    `use_like_fastpath` is the TEST-ONLY differential knob (default True =
    production), the same shape `eval_string_like.use_fastpath` carries and for
    the same reason: False forces every row through the Pike VM, which is the
    byte oracle the LIKE routing is diffed against. Production never
    passes it."""
    if use_like_fastpath:
        var like_pat = regexp_like_as_like_pattern(prog)
        if like_pat:
            return _regexp_like_via_like_kernel(col, like_pat.value())
    var n = col.length
    var bm = Bitmap.create(n)
    var has_nulls = col.null_count > 0 and col.validity
    var vbm = Bitmap.create_all_valid(n) if has_nulls else Bitmap.create_all_valid(0)
    var nulls_seen = 0
    var sc = RegexScratch()
    for i in range(n):
        if has_nulls and col.is_null(i):
            # NULL input -> NULL output.
            vbm.clear(i)
            nulls_seen += 1
            continue
        if prog.is_match_with(col.get_span(i), sc):
            bm.set(i)
    if has_nulls and nulls_seen > 0:
        var ba = BooleanArray.from_bitmap(bm^)
        ba.validity = Optional[Bitmap[HeapRegion]](vbm^)
        ba.null_count = nulls_seen
        return ba^
    return BooleanArray.from_bitmap(bm^)


# ---------------------------------------------------------------------------
# regexp_extract(col, pattern, group)  ->  StringArray
# ---------------------------------------------------------------------------

def eval_regexp_extract(col: StringArray[HeapRegion], prog: RegexProgram, group: Int) raises -> StringArray[HeapRegion]:
    """For each row: the substring matched by capture-`group` of the FIRST
    match of `prog` in the string (`group` 0 = the whole match).  No match
    (or the group did not participate, including a `group` index larger
    than the pattern's capture-group count) -> `''` (empty string, NOT NULL
    — DuckDB's `regexp_extract` semantics).  NULL row -> NULL.  `group` < 0
    or > 9 -> Error (matches DuckDB's "Group index must be between 0 and 9").
    """
    if group < 0 or group > 9:
        raise Error("regexp_extract: group index must be between 0 and 9, got " + String(group))
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var out_vals = List[String]()
    var null_idx = List[Int]()
    var sc = RegexScratch()
    for i in range(n):
        if has_nulls and col.is_null(i):
            out_vals.append(String(""))
            null_idx.append(i)
            continue
        var subj = col.get_span(i)
        var m = prog.find_with(subj, sc)
        if not m.matched:
            out_vals.append(String(""))
            continue
        var span = m.group_span(group)
        if span[0] < 0 or span[1] < 0:
            # Group did not participate.
            out_vals.append(String(""))
            continue
        out_vals.append(_bytes_to_str(subj, span[0], span[1]))
    var arr = StringArray.from_strings(out_vals)
    if has_nulls and len(null_idx) > 0:
        var vbm = Bitmap.create_all_valid(n)
        for k in range(len(null_idx)):
            vbm.clear(null_idx[k])
        arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
        arr.null_count = len(null_idx)
    return arr^


# ---------------------------------------------------------------------------
# regexp_match(col, pattern[, flags])  ->  ListArray<Utf8>
# ---------------------------------------------------------------------------
#
# `regexp_match` ALWAYS returns List<Utf8> (PostgreSQL `regexp_match` -> text[];
# DataFusion `regexp_match` -> List<Utf8>) — never a scalar, never JSON.  Per
# row:
#   - NULL input row          -> NULL list element.
#   - no match                -> NULL list element (PG: NULL on no match).
#   - match, pattern has 0 capture groups -> 1-element list [whole_match].
#   - match, pattern has N>0 capture groups -> N-element list of the captured
#     substrings of groups 1..N; a group that didn't participate in the match
#     -> the empty string '' in its slot (NOT a null element).
# ---------------------------------------------------------------------------

def eval_regexp_match(col: StringArray[HeapRegion], prog: RegexProgram) raises -> ListArray[HeapRegion]:
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var lists = List[List[String]]()
    var valid = List[Bool]()
    for i in range(n):
        if has_nulls and col.is_null(i):
            lists.append(List[String]())
            valid.append(False)
            continue
        var subj = _row_bytes(col, i)
        var m = prog.find(subj)
        if not m.matched:
            lists.append(List[String]())
            valid.append(False)
            continue
        var row = List[String]()
        if prog.n_groups == 0:
            row.append(_bytes_to_str(subj, m.start, m.end))
        else:
            for g in range(1, prog.n_groups + 1):
                var span = m.group_span(g)
                if span[0] < 0 or span[1] < 0:
                    row.append(String(""))
                else:
                    row.append(_bytes_to_str(subj, span[0], span[1]))
        lists.append(row^)
        valid.append(True)
    return ListArray.from_string_lists(lists, valid)


# ---------------------------------------------------------------------------
# regexp_split_to_array(col, pattern[, flags])  ->  ListArray<Utf8>
# ---------------------------------------------------------------------------
#
# Split each row on the non-overlapping, left-to-right matches of `prog`; the
# list elements are the between-match substrings.  Verified against DuckDB
# `regexp_split_to_array`:
#   - no match            -> 1-element list [whole_string].
#   - leading match       -> empty-string element at the front.
#   - trailing match      -> empty-string element at the back.
#   - consecutive matches -> empty-string element between them.
#   - empty input ''      -> 1-element list [''] (DuckDB).
#   - empty pattern ''    -> the pattern matches a zero-width position at every
#     byte boundary; DuckDB splits between every byte: 'abc' -> ['a','b','c']
#     (NO leading/trailing '' for the empty pattern — DuckDB collapses the
#     zero-width match at offsets 0 and len).  We match that.
#   - NULL input row      -> NULL list element.
# ---------------------------------------------------------------------------

def eval_regexp_split_to_array(col: StringArray[HeapRegion], prog: RegexProgram) raises -> ListArray[HeapRegion]:
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var lists = List[List[String]]()
    var valid = List[Bool]()
    for i in range(n):
        if has_nulls and col.is_null(i):
            lists.append(List[String]())
            valid.append(False)
            continue
        var subj = _row_bytes(col, i)
        var slen = len(subj)
        var matches = prog.find_all_in(subj)
        var row = List[String]()
        var cursor = 0
        for k in range(len(matches)):
            var ms = matches[k].start
            var me = matches[k].end
            # DuckDB's empty-pattern split: collapse the zero-width match at
            # offset 0 (no leading '') and at offset slen (no trailing '').
            if ms == me and (ms == 0 or ms == slen):
                continue
            row.append(_bytes_to_str(subj, cursor, ms))
            cursor = me
        row.append(_bytes_to_str(subj, cursor, slen))
        lists.append(row^)
        valid.append(True)
    return ListArray.from_string_lists(lists, valid)


# ---------------------------------------------------------------------------
# regexp_extract_all(col, pattern, group)  ->  ListArray<Utf8>
# ---------------------------------------------------------------------------
#
# Find ALL non-overlapping, left-to-right matches of `prog`; the list element
# for each match is the captured substring of group `group` (default 0 = the
# whole match).  Verified against DuckDB `regexp_extract_all`:
#   - no matches              -> empty list [] (NOT NULL).
#   - overlapping is excluded ('aa' on 'aaaa' -> ['aa','aa'], not 3).
#   - NULL input row          -> NULL list element.
#   - `group` < 0 or > 9      -> Error (same rule as `regexp_extract`).
#   - a group that didn't participate in a given match -> '' element.
#     (NOTE: DuckDB returns a NULL element here; we return '' for consistency
#     with the scalar `regexp_extract` — a deliberate divergence.)
# ---------------------------------------------------------------------------

def eval_regexp_extract_all(col: StringArray[HeapRegion], prog: RegexProgram, group: Int) raises -> ListArray[HeapRegion]:
    if group < 0 or group > 9:
        raise Error("regexp_extract_all: group index must be between 0 and 9, got " + String(group))
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var lists = List[List[String]]()
    var valid = List[Bool]()
    for i in range(n):
        if has_nulls and col.is_null(i):
            lists.append(List[String]())
            valid.append(False)
            continue
        var subj = _row_bytes(col, i)
        var matches = prog.find_all_in(subj)
        var row = List[String]()
        for k in range(len(matches)):
            var span = matches[k].group_span(group)
            if span[0] < 0 or span[1] < 0:
                row.append(String(""))
            else:
                row.append(_bytes_to_str(subj, span[0], span[1]))
        lists.append(row^)
        valid.append(True)
    return ListArray.from_string_lists(lists, valid)


# ---------------------------------------------------------------------------
# regexp_replace(col, pattern, replacement[, flags])  ->  StringArray
# ---------------------------------------------------------------------------
#
# Replace the FIRST match of `prog` in each row (or ALL non-overlapping
# matches when `replace_all`) with the *substituted* `replacement` template.
#
# Replacement template syntax — the RE2 / PostgreSQL `\N` "rewrite" syntax
# (NOT DataFusion's `${N}` / `$N`, which we intentionally do NOT accept; `$N`
# is a literal `$N`):
#   \0          -> the whole match (group 0)
#   \1 .. \9    -> the substring of capture group N (exactly one digit; `\10`
#                  is `\1` followed by a literal `0`).  A group that did not
#                  participate in the match -> the empty string '' in its slot
#                  (NOT an error).
#   \\          -> a literal backslash
#   \<anything else>            -> the template is INVALID (see below)
#   <any other char incl. & $ %> -> that literal char
#
# Invalid template (an out-of-range backref `\N` where N > the pattern's
# capture-group count, an unrecognized escape `\&` / `\q` / ..., or a
# trailing `\`):  RE2's `Replace` / `GlobalReplace` returns false in this
# case, and DuckDB then returns the *original string unchanged*.  We match
# that: an invalid template -> the kernel echoes the input column verbatim.
# (Documented divergence-from-error, matches DuckDB exactly.)
#
# Zero-width-match semantics under `replace_all` (RE2's `GlobalReplace`):
#   - regexp_replace('abc', '', 'X', 'g')  -> 'XaXbXcX'  (X inserted before
#     every byte AND at the end)
#   - regexp_replace('aaa', 'a*', 'X', 'g') -> 'X'        (a* matches 'aaa' at
#     offset 0; the zero-width match at offset 3 immediately follows the end
#     of that match and is SKIPPED — RE2 does not allow an empty match right
#     after a previous match)
#   - regexp_replace('aaab', 'a*', 'X', 'g') -> 'XbX'    (a* -> 'aaa', skip the
#     empty match at pos 3, copy 'b', a* -> '' at pos 4 (not adjacent to a
#     match end), -> 'X')
#   - regexp_replace('aaaa', 'aa', 'X', 'g') -> 'XX'
#   - regexp_replace('aaa', 'a*', 'X')       -> 'X'       (first-only: a*->'aaa')
# NULL input row -> NULL output row.
# ---------------------------------------------------------------------------


def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("9"))


def rewrite_template_valid(template: String, n_groups: Int) -> Bool:
    """True iff `template` is a legal RE2 `\\N` rewrite string for a pattern
    with `n_groups` capture groups: a `\\` must be followed by exactly one of
    `\\` (literal backslash) or a digit `0..9` (a backref; the digit must be
    <= n_groups), and there must be no trailing `\\`.  Mirrors DuckDB's
    behavior (an invalid rewrite string -> the original is returned unchanged
    rather than an error)."""
    var bs = template.as_bytes()
    var i = 0
    var nb = len(bs)
    while i < nb:
        if bs[i] == UInt8(ord("\\")):
            if i + 1 >= nb:
                return False  # trailing backslash
            var nxt = bs[i + 1]
            if nxt == UInt8(ord("\\")):
                i += 2
            elif _is_digit(nxt):
                var g = Int(nxt) - ord("0")
                if g > n_groups:
                    return False  # out-of-range backref
                i += 2
            else:
                return False  # unrecognized escape
        else:
            i += 1
    return True


def _append_rewrite(mut out: List[UInt8], template_bytes: List[UInt8], m: RegexMatch, subj: List[UInt8]):
    """Append the substituted `template_bytes` to `out` for match `m` over
    `subj`.  Assumes the template has already been validated by
    `rewrite_template_valid` (so every `\\` is `\\\\` or `\\<digit>` and the
    digit is in range)."""
    var nb = len(template_bytes)
    var i = 0
    while i < nb:
        var c = template_bytes[i]
        if c == UInt8(ord("\\")) and i + 1 < nb:
            var nxt = template_bytes[i + 1]
            if nxt == UInt8(ord("\\")):
                out.append(UInt8(ord("\\")))
                i += 2
                continue
            elif _is_digit(nxt):
                var g = Int(nxt) - ord("0")
                var span = m.group_span(g)
                if span[0] >= 0 and span[1] >= 0:
                    for j in range(span[0], span[1]):
                        out.append(subj[j])
                # else: non-participating group -> empty substitution
                i += 2
                continue
        out.append(c)
        i += 1


def _append_rewrite_into(mut out: ArrowStringBuilder, template_bytes: List[UInt8], m: RegexMatch, subj: Span[UInt8, _]):
    """`_append_rewrite`, writing straight into the Arrow byte buffer.

    Byte-for-byte the same output as `_append_rewrite`; the difference is that
    a literal RUN of the template and a whole capture group each move as ONE
    `extend` (a memcpy) instead of a per-byte `append`, and nothing is staged
    in an intermediate `List`/`String` on the way.
    """
    var nb = len(template_bytes)
    var tspan = Span(template_bytes)
    var i = 0
    var run = 0                  # start of the literal run not yet flushed
    while i < nb:
        var c = template_bytes[i]
        if c == UInt8(ord("\\")) and i + 1 < nb:
            var nxt = template_bytes[i + 1]
            if nxt == UInt8(ord("\\")):
                # `\\` -> one literal backslash: flush THROUGH the first of the
                # two, then resume past the second.
                out.push_bytes_partial(tspan[run : i + 1])
                i += 2
                run = i
                continue
            elif _is_digit(nxt):
                if i > run:
                    out.push_bytes_partial(tspan[run:i])
                var g = Int(nxt) - ord("0")
                var span = m.group_span(g)
                if span[0] >= 0 and span[1] >= 0:
                    out.push_bytes_partial(subj[span[0] : span[1]])
                # else: non-participating group -> empty substitution
                i += 2
                run = i
                continue
        i += 1
    if i > run:
        out.push_bytes_partial(tspan[run:i])


def _replace_into(
    prog: RegexProgram,
    subj: Span[UInt8, _],
    template_bytes: List[UInt8],
    replace_all: Bool,
    mut out: ArrowStringBuilder,
    mut sc: RegexScratch,
):
    """`_replace_one`, streamed.  Same control flow, same match sequence, same
    RE2 `GlobalReplace` empty-match rule — but the result is assembled
    IN PLACE in `out`'s Arrow data buffer and closed with one `end_value()`,
    and the capture engine runs on the caller's `sc`.  Every `find_from_with`
    below is a capture call, so `RegexProgram.find_from_with_engine` runs
    BitState for it when `prog_len * (text_len + 1) <= 256 Ki bits` (RE2's own
    dispatch for this call shape; typical URL-length subjects qualify) and
    the Pike VM otherwise.  The two engines are held to one answer by
    `komira_column_kernels/tests/test_regexp_bitstate_differential.mojo`.

    ⛔ IT MUST STAY A MIRROR OF `_replace_one`.  A test diffs the two row by
    row (the column kernel vs the scalar spelling), which is the only thing
    that keeps them honest.
    """
    var slen = len(subj)
    var copied = 0               # bytes [0:copied) already pushed
    var lastend = -1             # end offset of the previous match (-1 = none)
    var pos = 0
    while pos <= slen:
        var m = prog.find_from_with(subj, pos, sc)
        if not m.matched:
            break
        var ms = m.start
        var me = m.end
        if ms == me and ms == lastend:
            # Empty match immediately after the previous match: skip it
            # (RE2's GlobalReplace disallows this).
            if ms >= slen:
                out.push_bytes_partial(subj[copied:ms])
                copied = ms
                break
            out.push_bytes_partial(subj[copied : ms + 1])
            copied = ms + 1
            pos = ms + 1
            continue
        out.push_bytes_partial(subj[copied:ms])
        _append_rewrite_into(out, template_bytes, m, subj)
        copied = me
        lastend = me
        if not replace_all:
            break
        if me > ms:
            pos = me
        else:
            # Zero-width match: copy one byte and advance to avoid an
            # infinite loop.
            if ms < slen:
                out.push_bytes_partial(subj[ms : ms + 1])
                copied = ms + 1
            pos = ms + 1
    out.push_bytes_partial(subj[copied:slen])
    out.end_value()


def _replace_one(prog: RegexProgram, subj: List[UInt8], template_bytes: List[UInt8], replace_all: Bool) -> List[UInt8]:
    """Apply `prog` + the (already-validated) rewrite `template_bytes` to
    `subj`, replacing the first match (or all non-overlapping matches when
    `replace_all`).  Returns the new byte list."""
    var out = List[UInt8]()
    var slen = len(subj)
    var copied = 0           # bytes [0:copied) already in `out`
    var lastend = -1         # end offset of the previous match (-1 = none)
    var pos = 0
    var count = 0
    while pos <= slen:
        var m = prog.find_from(subj, pos)
        if not m.matched:
            break
        var ms = m.start
        var me = m.end
        if ms == me and ms == lastend:
            # Empty match immediately after the previous match: skip it
            # (RE2's GlobalReplace disallows this).  Copy up to here, then
            # advance by one byte.
            for j in range(copied, ms):
                out.append(subj[j])
            if ms >= slen:
                copied = ms
                break
            out.append(subj[ms])
            copied = ms + 1
            pos = ms + 1
            continue
        # Perform the replacement.
        for j in range(copied, ms):
            out.append(subj[j])
        _append_rewrite(out, template_bytes, m, subj)
        copied = me
        count += 1
        lastend = me
        if not replace_all:
            break
        if me > ms:
            pos = me
        else:
            # Zero-width match: copy one byte and advance to avoid an
            # infinite loop.
            if ms < slen:
                out.append(subj[ms])
                copied = ms + 1
            pos = ms + 1
    for j in range(copied, slen):
        out.append(subj[j])
    _ = count
    return out^


# --- _ReplaceMemo tuning.  Every one of these is measured, not chosen: see the
# --- struct's docstring for the trade-off they balance.
comptime _MEMO_PROBE_ROWS: Int = 4096   # sample this many rows, then decide
comptime _MEMO_MIN_HIT_NUM: Int = 1     # keep the memo iff hits/probed >= 1/8
comptime _MEMO_MIN_HIT_DEN: Int = 8
comptime _MEMO_MIN_CAP: Int = 256
comptime _MEMO_MAX_CAP: Int = 1 << 18   # 262,144 slots -> ~10 MB of Int lists


def _replace_into_arena(
    prog: RegexProgram,
    subj: Span[UInt8, _],
    template_bytes: List[UInt8],
    replace_all: Bool,
    mut arena: List[UInt8],
    mut sc: RegexScratch,
):
    """`_replace_into`, writing into a plain byte arena instead of an
    `ArrowStringBuilder`.

    ⛔ IT MUST STAY A MIRROR OF `_replace_into` — same control flow, same
    match sequence, same RE2 `GlobalReplace` empty-match rule.  The ONLY
    difference is the sink: a `List[UInt8]` that carries no offset array, so
    there is no `end_value()`.  `_ReplaceMemo` needs the produced bytes to
    still be readable after they are emitted (to re-emit them for a repeated
    subject), and an `ArrowStringBuilder`'s data buffer cannot be read while it
    is being appended to — a push may reallocate it.

    The three kernels are held together by a test that diffs the memoised
    column against the one-shot scalar spelling row by row.
    """
    var slen = len(subj)
    var copied = 0               # bytes [0:copied) already pushed
    var lastend = -1             # end offset of the previous match (-1 = none)
    var pos = 0
    while pos <= slen:
        var m = prog.find_from_with(subj, pos, sc)
        if not m.matched:
            break
        var ms = m.start
        var me = m.end
        if ms == me and ms == lastend:
            if ms >= slen:
                arena.extend(subj[copied:ms])
                copied = ms
                break
            arena.extend(subj[copied : ms + 1])
            copied = ms + 1
            pos = ms + 1
            continue
        arena.extend(subj[copied:ms])
        _append_rewrite_into_arena(arena, template_bytes, m, subj)
        copied = me
        lastend = me
        if not replace_all:
            break
        if me > ms:
            pos = me
        else:
            if ms < slen:
                arena.extend(subj[ms : ms + 1])
                copied = ms + 1
            pos = ms + 1
    arena.extend(subj[copied:slen])


def _append_rewrite_into_arena(mut arena: List[UInt8], template_bytes: List[UInt8], m: RegexMatch, subj: Span[UInt8, _]):
    """`_append_rewrite_into`, with a `List[UInt8]` sink."""
    var nb = len(template_bytes)
    var tspan = Span(template_bytes)
    var i = 0
    var run = 0
    while i < nb:
        var c = template_bytes[i]
        if c == UInt8(ord("\\")) and i + 1 < nb:
            var nxt = template_bytes[i + 1]
            if nxt == UInt8(ord("\\")):
                arena.extend(tspan[run : i + 1])
                i += 2
                run = i
                continue
            elif _is_digit(nxt):
                if i > run:
                    arena.extend(tspan[run:i])
                var g = Int(nxt) - ord("0")
                var span = m.group_span(g)
                if span[0] >= 0 and span[1] >= 0:
                    arena.extend(subj[span[0] : span[1]])
                i += 2
                run = i
                continue
        i += 1
    if i > run:
        arena.extend(tspan[run:i])


struct _ReplaceMemo(Movable):
    """RUN THE PATTERN ONCE PER DISTINCT VALUE, not once per row.

    ⭐ WHY.  `regexp_replace` over a real column is dominated by REPEATED
    subjects.  A web-log URL column (e.g. a referrer) shows ~4x reuse in a
    4,096-row window and ~6x in a row-group-sized one, and memoising cuts the
    whole kernel ~3x with byte-identical output.

    THE KEY IS THE SUBJECT BYTES, NOT A DICTIONARY CODE.  Such a column may
    arrive dictionary-encoded in only some of its column chunks, so a
    dictionary-keyed memo could reach only part of it; keying on the bytes
    reaches all of it, and is independent of how the scan chose to encode
    them.

    ⛔ IT MUST NOT PUNISH A COLUMN WITH NO REPEATS.  On an all-distinct column
    the memo costs roughly +6%.  So the table SAMPLES: after `_PROBE_ROWS`
    rows, a hit rate below `_MIN_HIT_NUM/_MIN_HIT_DEN` turns it off for the
    rest of the call and the kernel runs without it.

    The value arena is a plain `List[UInt8]`, NOT the output builder's own data
    buffer: re-emitting a remembered value means READING bytes that were
    already produced, and an `ArrowStringBuilder` push may reallocate the
    buffer being read.
    """

    var enabled: Bool
    var arena: List[UInt8]
    var _mask: Int
    var _hash: List[UInt64]
    var _koff: List[Int]      # offset into `_kbytes`; -1 = empty slot
    var _klen: List[Int]
    var _vlo: List[Int]
    var _vhi: List[Int]
    var _kbytes: List[UInt8]  # OUR OWN copy of every remembered subject
    var _live: Int
    var _limit: Int
    var _hits: Int
    var _probed: Int
    var _decided: Bool

    def __init__(out self, n_rows: Int):
        var cap = _MEMO_MIN_CAP
        while cap < n_rows * 2 and cap < _MEMO_MAX_CAP:
            cap = cap * 2
        self.enabled = n_rows >= 64
        self.arena = List[UInt8]()
        self._mask = cap - 1
        self._hash = List[UInt64](length=cap, fill=0)
        self._koff = List[Int](length=cap, fill=-1)
        self._klen = List[Int](length=cap, fill=0)
        self._vlo = List[Int](length=cap, fill=0)
        self._vhi = List[Int](length=cap, fill=0)
        self._kbytes = List[UInt8]()
        self._live = 0
        self._limit = (cap * 5) // 8
        self._hits = 0
        self._probed = 0
        self._decided = False

    @always_inline
    def _hash_of(self, subj: Span[UInt8, _]) -> UInt64:
        """The memo key hash. 64-bit, and the (hash, length, bytes) triple is
        what decides equality — the hash alone never does, so the CHOICE of
        hash cannot change an answer, only the slot a subject lands in.

        ⭐ WHY NOT FNV-1a, ONE BYTE AT A TIME. The hash runs on EVERY row, hit
        or miss, and FNV's recurrence `h = (h ^ byte) * prime` is a SERIAL
        multiply chain with one ~3-4-cycle-latency imul per BYTE. Over ~80-byte
        subjects xxHash64 is ~2.75x faster (≈55 vs ≈150 ns/row), because it
        strides 32 bytes per round across FOUR INDEPENDENT accumulators, so the
        multiply chains overlap instead of serialising.

        `komira_dynamic_filter.bloom_filter.xxhash64` is this library's own
        spec-compliant xxHash64 (seed 0) and is also the hash of record on
        the `count(distinct <string>)` parallel path. Reusing it rather than
        hand-rolling a
        second one is deliberate: a memo whose hash nobody else exercises is a
        memo whose hash nobody else tests."""
        return xxhash64(subj)

    def find(mut self, subj: Span[UInt8, _]) -> Int:
        """The slot for `subj`: an occupied one iff the subject is remembered.

        Returns a slot index; `is_hit(slot)` says which it is.  The caller must
        pass the SAME subject to `remember`.
        """
        var h = self._hash_of(subj)
        var slot = Int(h & UInt64(self._mask))
        var ln = len(subj)
        # ⭐ THE KEY COMPARE IS THE MEMO'S SECOND WHOLE-SUBJECT WALK, AND IT
        # RUNS ON EVERY HIT — on a repetitive column, most rows. A byte-at-a-time
        # `List` index loop is ~5x slower than a 16-lane vector ladder at an
        # ~80-byte mean. `bytes_equal` is this library's kernel for exactly that,
        # is value-identical to `bytes_equal_scalar` by construction, and is
        # covered by mutation tests; its length short-circuit is
        # redundant here (we already tested `_klen`) and costs one predictable
        # branch.
        var sspan = subj.as_imm()
        while self._koff[slot] >= 0:
            if self._hash[slot] == h and self._klen[slot] == ln:
                var ko = self._koff[slot]
                # The borrow of `_kbytes` is scoped to this comparison so it
                # cannot overlap the `_hash[slot] = h` store below.
                if bytes_equal(
                    Span(self._kbytes).as_imm()[ko : ko + ln], sspan
                ):
                    return slot
            slot = (slot + 1) & self._mask
        # `_hash` is written at insert time; stash it so `remember` need not
        # re-hash the subject.
        self._hash[slot] = h
        return slot

    @always_inline
    def is_hit(self, slot: Int) -> Bool:
        return self._koff[slot] >= 0

    def emit_hit(mut self, slot: Int, mut out: ArrowStringBuilder):
        self._hits += 1
        self._probed += 1
        out.push_bytes(Span(self.arena)[self._vlo[slot] : self._vhi[slot]])
        self._maybe_decide()

    def _maybe_decide(mut self):
        """SAMPLE, THEN DECIDE — once, from BOTH arms.

        ⛔ THE COUNTER IS BUMPED ON A HIT *AND* ON A MISS, so this cannot key
        on `_probed == _MEMO_PROBE_ROWS` from one arm only: if the boundary row
        happens to be a hit, an equality test in the miss arm never fires again
        and the memo can never turn itself off. `>=` plus a one-shot flag is
        what makes the decision reachable from whichever arm gets there first.
        """
        if self._decided or self._probed < _MEMO_PROBE_ROWS:
            return
        self._decided = True
        if self._hits * _MEMO_MIN_HIT_DEN < self._probed * _MEMO_MIN_HIT_NUM:
            self.enabled = False

    def remember(mut self, slot: Int, subj: Span[UInt8, _], vlo: Int, vhi: Int):
        self._probed += 1
        self._maybe_decide()
        if not self.enabled:
            return
        if self._live >= self._limit:
            # Full.  Stop inserting — every already-remembered value still
            # answers, and probing still terminates because the load factor
            # never reaches 1.
            return
        var ko = len(self._kbytes)
        self._kbytes.extend(subj)
        self._koff[slot] = ko
        self._klen[slot] = len(subj)
        self._vlo[slot] = vlo
        self._vhi[slot] = vhi
        self._live += 1


def eval_regexp_replace(col: StringArray[HeapRegion], prog: RegexProgram, replacement: String, replace_all: Bool) raises -> StringArray[HeapRegion]:
    """`regexp_replace(col, pattern, replacement[, flags])` -> Utf8.  Replace
    the first match of `prog` (or all non-overlapping matches when
    `replace_all`) in each row with the substituted `replacement` template
    (`\\N` rewrite syntax — see the module-level doc above).  NULL row ->
    NULL.  An invalid replacement template -> the input string is returned
    unchanged for every row (matches DuckDB)."""
    # ⭐ NO PER-ROW MATERIALIZATION.  Nothing between the input bytes and the
    # output bytes is copied except by the regex itself: the subject is a
    # borrowed `Span` over the Arrow data buffer (no per-row `List[UInt8]`
    # copy), the result is assembled directly in the Arrow output buffer (no
    # per-row `List[UInt8]`, no `List[String]` staging re-serialized by
    # `StringArray.from_strings`), and the VM's thread lists are hoisted to one
    # `RegexScratch` for the whole column. Staging a large URL column as one
    # heap `String` per row costs gigabytes.
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var template_valid = rewrite_template_valid(replacement, prog.n_groups)
    var template_bytes = _str_bytes(replacement)
    var out = ArrowStringBuilder()
    out.reserve_rows(n)
    out.reserve_bytes(col.data_length)
    var sc = RegexScratch()
    if not template_valid:
        # Invalid rewrite template -> every row is its own input, unchanged
        # (DuckDB).  The VM never runs, so there is nothing to memoise; taking
        # the memo here would be pure overhead.
        for i in range(n):
            if has_nulls and col.is_null(i):
                out.push_null()
                continue
            out.push_bytes(col.get_span(i))
        return out^.build_string_array()
    var memo = _ReplaceMemo(n)
    # RXCENSUS: the hit/miss/hashed-bytes split is the only way to price
    # "widen the memo beyond one batch", and it cannot be derived from outside
    # this loop. Comptime-erased unless RXCENSUS_ROWS_ENABLED.
    var c_hits = 0
    var c_vm = 0
    var c_keybytes = 0
    for i in range(n):
        if has_nulls and col.is_null(i):
            out.push_null()
            continue
        var subj = col.get_span(i)
        if not memo.enabled:
            _replace_into(prog, subj, template_bytes, replace_all, out, sc)
            comptime if RXCENSUS_ROWS_ENABLED:
                c_vm += 1
            continue
        var slot = memo.find(subj)
        comptime if RXCENSUS_ROWS_ENABLED:
            c_keybytes += len(subj)
        if memo.is_hit(slot):
            memo.emit_hit(slot, out)
            comptime if RXCENSUS_ROWS_ENABLED:
                c_hits += 1
            continue
        var alo = len(memo.arena)
        _replace_into_arena(prog, subj, template_bytes, replace_all, memo.arena, sc)
        out.push_bytes(Span(memo.arena)[alo : len(memo.arena)])
        memo.remember(slot, subj, alo, len(memo.arena))
        comptime if RXCENSUS_ROWS_ENABLED:
            c_vm += 1
    rxcensus_add(RXC_REPLACE_CALLS, 1)
    rxcensus_add(RXC_REPLACE_ROWS, n)
    if not memo.enabled:
        rxcensus_add(RXC_MEMO_OFF_CALLS, 1)
    comptime if RXCENSUS_ROWS_ENABLED:
        rxcensus_add(RXC_MEMO_HITS, c_hits)
        rxcensus_add(RXC_MEMO_VM, c_vm)
        rxcensus_add(RXC_MEMO_KEYBYTES, c_keybytes)
    return out^.build_string_array()


# ---------------------------------------------------------------------------
# regexp_count(col, pattern[, flags])  ->  Int64   (PostgreSQL semantics)
# ---------------------------------------------------------------------------
#
# The number of non-overlapping, left-to-right matches of `prog` in each row
# (= len(prog.find_all_in(bytes))).  No match -> 0 (NOT NULL).  NULL input row
# -> NULL.  PostgreSQL's `regexp_count(string, pattern[, start[, flags]])` (the
# `start` arg is not supported — PG's `start` defaults to 1).  DuckDB does not
# have `regexp_count` (v1.5.0).
#
# Zero-width-match interaction (matches RE2 `find_all`):
#   regexp_count('abc', '')  -> 4   (a zero-width match before every byte and
#                                   one at the end — find_all_in advances by 1
#                                   on a zero-width match)
#   regexp_count('aaa', 'a*') -> 2  (a* -> 'aaa' [0,3); the zero-width match at
#                                   offset 3 IS counted by find_all_in — note
#                                   this differs from regexp_replace's
#                                   GlobalReplace which skips it)
# ---------------------------------------------------------------------------

def eval_regexp_count(col: StringArray[HeapRegion], prog: RegexProgram) raises -> PrimitiveArray[DType.int64]:
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var out = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nulls = 0
    var sc = RegexScratch()
    for i in range(n):
        if has_nulls and col.is_null(i):
            out.validity.value().clear(i)
            nulls += 1
            continue
        out.set(i, Int64(len(prog.find_all_in_with(col.get_span(i), sc))))
    out.null_count = nulls
    return out^


# ---------------------------------------------------------------------------
# regexp_instr(col, pattern[, flags])  ->  Int64   (PostgreSQL semantics)
# ---------------------------------------------------------------------------
#
# The 1-based BYTE position of the start of the first match (0 if no match).
# NULL input row -> NULL.  PostgreSQL's `regexp_instr(string, pattern[, start[,
# N[, endoption[, flags[, subexpr]]]]])` — only the `(string, pattern[, flags])`
# form is supported; the `start`/`N`/`endoption`/`subexpr` args are not
# (their PG defaults: start=1, N=1, endoption=0, subexpr=0 = whole
# match).  Note our positions are BYTE positions (the matcher is byte-oriented);
# PG's are character positions — for ASCII subjects these coincide.
#   regexp_instr('abcabc', 'b')   -> 2
#   regexp_instr('abcabc', 'z')   -> 0
#   regexp_instr('abc', 'a')      -> 1
#   regexp_instr('xxabc', 'abc')  -> 3
# ---------------------------------------------------------------------------

def eval_regexp_instr(col: StringArray[HeapRegion], prog: RegexProgram) raises -> PrimitiveArray[DType.int64]:
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var out = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nulls = 0
    var sc = RegexScratch()
    for i in range(n):
        if has_nulls and col.is_null(i):
            out.validity.value().clear(i)
            nulls += 1
            continue
        var m = prog.find_with(col.get_span(i), sc)
        if m.matched:
            out.set(i, Int64(m.start + 1))
        else:
            out.set(i, Int64(0))
    out.null_count = nulls
    return out^


# ---------------------------------------------------------------------------
# regexp_substr(col, pattern[, flags])  ->  StringArray   (PG/Oracle semantics)
# ---------------------------------------------------------------------------
#
# The first matched substring (= group 0 of the first match).  No match -> NULL
# (PostgreSQL/Oracle `regexp_substr` semantics — note this DIFFERS from our
# `regexp_extract`, which returns '' on no match per DuckDB; documented
# divergence, both functions following their respective oracle).  NULL input row
# -> NULL.  PG's `regexp_substr(string, pattern[, start[, N[, flags[, subexpr]]]])`
# — only the `(string, pattern[, flags])` form is supported.
#   regexp_substr('1abc2', '[a-z]+')  -> 'abc'
#   regexp_substr('abc', 'x')         -> NULL
# ---------------------------------------------------------------------------

def eval_regexp_substr(col: StringArray[HeapRegion], prog: RegexProgram) raises -> StringArray[HeapRegion]:
    var n = col.length
    var has_nulls = col.null_count > 0 and col.validity
    var out_vals = List[String]()
    var null_idx = List[Int]()
    var sc = RegexScratch()
    for i in range(n):
        if has_nulls and col.is_null(i):
            out_vals.append(String(""))
            null_idx.append(i)
            continue
        var subj = col.get_span(i)
        var m = prog.find_with(subj, sc)
        if not m.matched:
            # No match -> NULL (PG/Oracle).
            out_vals.append(String(""))
            null_idx.append(i)
            continue
        out_vals.append(_bytes_to_str(subj, m.start, m.end))
    var arr = StringArray.from_strings(out_vals)
    if len(null_idx) > 0:
        var vbm = Bitmap.create_all_valid(n)
        for k in range(len(null_idx)):
            vbm.clear(null_idx[k])
        arr.validity = Optional[Bitmap[HeapRegion]](vbm^)
        arr.null_count = len(null_idx)
    return arr^


# ---------------------------------------------------------------------------
# regexp_full_match(col, pattern[, flags])  ->  BooleanArray   (DuckDB)
# ---------------------------------------------------------------------------
#
# True iff the ENTIRE string matches `pattern` (anchored both ends).  Implemented
# by wrapping the user's pattern in `\A(?:...)\z` before `RegexProgram.compile`
# (the standard RE2 `FullMatch` desugaring; the `(?:...)` non-capturing group is
# needed so an alternation `a|b` becomes `\A(?:a|b)\z`, not `\Aa|b\z`).  NULL
# input row -> NULL.  Matches DuckDB's `regexp_full_match`.
#
# `compile_full_match_program` is the helper the dispatch arms use to build the
# anchored program; `eval_regexp_full_match` then just runs `is_match` on it
# (with the anchors, `is_match` == "does the whole string match").
#   regexp_full_match('abc', 'abc')   -> true
#   regexp_full_match('abc', 'ab')    -> false
#   regexp_full_match('abc', 'a.c')   -> true
#   regexp_full_match('b', 'a|b')     -> true   (proves the (?:...) wrapper)
#   regexp_full_match('ab', 'a|b')    -> false
#   regexp_full_match('', '')         -> true
#   regexp_full_match('abc', '')      -> false
# ---------------------------------------------------------------------------

def compile_full_match_program(pattern: String, flags: String = "") raises -> RegexProgram:
    """Compile `pattern` wrapped in `\\A(?:...)\\z` (the RE2 `FullMatch`
    desugaring).  Use for `regexp_full_match`.  Raises on an invalid pattern
    (same diagnostics as `RegexProgram.compile`)."""
    return RegexProgram.compile("\\A(?:" + pattern + ")\\z", flags)


def eval_regexp_full_match(col: StringArray[HeapRegion], prog: RegexProgram) raises -> BooleanArray:
    """For each row: True iff `prog` (which the caller must have built via
    `compile_full_match_program`) matches.  NULL row -> NULL."""
    var n = col.length
    var bm = Bitmap.create(n)
    var has_nulls = col.null_count > 0 and col.validity
    var vbm = Bitmap.create_all_valid(n) if has_nulls else Bitmap.create_all_valid(0)
    var nulls_seen = 0
    var sc = RegexScratch()
    for i in range(n):
        if has_nulls and col.is_null(i):
            vbm.clear(i)
            nulls_seen += 1
            continue
        if prog.is_match_with(col.get_span(i), sc):
            bm.set(i)
    if has_nulls and nulls_seen > 0:
        var ba = BooleanArray.from_bitmap(bm^)
        ba.validity = Optional[Bitmap[HeapRegion]](vbm^)
        ba.null_count = nulls_seen
        return ba^
    return BooleanArray.from_bitmap(bm^)


# ---------------------------------------------------------------------------
# Helpers used by the dispatch arms / tests.
# ---------------------------------------------------------------------------

def split_g_flag(flags: String) -> Tuple[String, Bool]:
    """Split a `regexp_replace`-style flags string into (pattern_flags, has_g):
    `g` means replace-all (it is NOT a pattern flag — strip it before passing
    the rest to `RegexProgram.compile`); `i`/`m`/`s`/`x` pass through.  A
    duplicated `g` is fine.  Unknown letters are left in `pattern_flags` so
    `RegexProgram.compile` raises a clear error on them."""
    var bs = flags.as_bytes()
    var out = String("")
    var has_g = False
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("g")):
            has_g = True
        else:
            out += chr(Int(bs[i]))
    return (out^, has_g)


def regexp_replace_scalar(subject: String, prog: RegexProgram, replacement: String, replace_all: Bool) raises -> String:
    """Convenience: `regexp_replace` on a single string."""
    if not rewrite_template_valid(replacement, prog.n_groups):
        return subject.copy()
    var rep = _replace_one(prog, _str_bytes(subject), _str_bytes(replacement), replace_all)
    return _bytes_to_str(rep, 0, len(rep))


def regexp_like_scalar(subject: String, prog: RegexProgram) -> Bool:
    """Convenience: does `subject` contain a match for `prog`?"""
    return prog.is_match(_str_bytes(subject))


def regexp_extract_scalar(subject: String, prog: RegexProgram, group: Int) raises -> String:
    """Convenience: capture-`group` substring of the first match (0 = whole
    match); `''` on no match / non-participating group / group > n_groups."""
    if group < 0 or group > 9:
        raise Error("regexp_extract: group index must be between 0 and 9")
    var b = _str_bytes(subject)
    var m = prog.find(b)
    if not m.matched:
        return String("")
    var span = m.group_span(group)
    if span[0] < 0 or span[1] < 0:
        return String("")
    return _bytes_to_str(b, span[0], span[1])


def regexp_count_scalar(subject: String, prog: RegexProgram) -> Int:
    """Convenience: number of non-overlapping matches of `prog` in `subject`."""
    return len(prog.find_all_in(_str_bytes(subject)))


def regexp_instr_scalar(subject: String, prog: RegexProgram) -> Int:
    """Convenience: 1-based byte position of the first match (0 if none)."""
    var m = prog.find(_str_bytes(subject))
    if m.matched:
        return m.start + 1
    return 0


def regexp_full_match_scalar(subject: String, prog: RegexProgram) -> Bool:
    """Convenience: does `prog` (built via `compile_full_match_program`) match
    `subject`?"""
    return prog.is_match(_str_bytes(subject))
