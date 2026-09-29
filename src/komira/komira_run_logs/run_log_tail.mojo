# =============================================================================
# komira_run_logs/run_log_tail.mojo — the run-log PAGE, parsed through a FIELD
#   ALLOW-LIST, and rendered BOUNDED.
# =============================================================================
#
# THE WIRE SHAPE, from the pipeline manager's run-log handler (and forwarded
# VERBATIM by the api passthrough at `.../apps/runs/{runId}/logs?after=&limit=`):
#
#     {"run_id":"<uuid>",
#      "lines":[{"seq":1,"ts":1712345678000000,"level":"info",
#                "step":"build","message":"..."}],
#      "next_cursor":7,"done":false}
#
# `seq`/`ts` are BARE int64 numbers (the emitter's stated convention — proto3-JSON
# quoted-int64 is NOT used); `done` is a bare JSON bool; `level`/`step`/`message`
# are JSON strings escaped by the emitter's JSON escape (`\"` `\\` `\n` `\r`
# `\t` and nothing else).
#
# ── ⛔ THE ALLOW-LIST IS THE SECURITY BOUNDARY, AND IT IS ON *FIELDS* ─────────
# `RUN_LOG_FIELD_ALLOWLIST` is the complete set of keys that can leave this
# parser. A key that is not in it is SKIPPED — not stored, not rendered, not
# counted. This matters because the thing on the other end of this pipe is an
# operator's terminal during a failed deploy, and the deploy surface next to it
# includes routes whose 2xx body carries a LIVE GRANT TOKEN. Two rules, and the
# first is the one that actually holds:
#
#   1. ⛔ A RESPONSE BODY IS NEVER ECHOED. Not on a 4xx, not on a 5xx, not on an
#      unparseable 200. `parse_run_logs_body` reports a byte COUNT and a position
#      and never the bytes — see `RunLogTail.failed`. An error path that prints
#      "the server said: <body>" is how a token reaches a log, and it is the
#      easiest thing in the world to write by accident.
#   2. Only the five allow-listed fields of a `lines[]` object are read, so a
#      field someone adds upstream cannot start printing itself here. Widening
#      the set is a deliberate edit to ONE list, which is the point.
#
# `redact_secretish` is DEFENCE IN DEPTH ON TOP OF THAT, never the boundary: it
# scrubs `Bearer <...>` / `token=<...>` / `"token":"<...>"` shaped runs out of a
# message an upstream writer should not have put there in the first place.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# Flat value PODs (Int + String + List[POD]) — no pointer field, so no
# stale-pointer hazard across destroy and recreate. ZERO UnsafePointer, no
# wildcard origin, no FFI, no transport. The parser is a SCAN, not a general
# JSON reader, but
# it is a *structural* scan over key/value pairs rather than a substring hunt, so
# a `message` whose text contains `"level":"` cannot fool it. Mojo 1.0.0b2.
# =============================================================================


comptime RUN_LOG_FIELD_ALLOWLIST: String = "seq,ts,level,step,message"
"""★ THE COMPLETE set of `lines[]` object keys this library will read or print.

Stated as ONE comptime string so it is greppable and so a reviewer can see the
whole allow-list without reading the scanner. Every other key in a log-line
object is skipped by `_parse_line_object`. Widening this is a deliberate edit
here AND in that function — there is no path by which a new upstream field
starts appearing in an operator's terminal on its own."""


# =============================================================================
# ★★ THE STREAM KIND — WHO THE RECORDS CAME FROM.
#
# ⛔ THE DEFECT THIS PREVENTS. A renderer that speaks one vocabulary would say,
# over a CLOUD RUN CONTAINER'S STDOUT:
#
#     run-log: NO STAGE RECORDS for run <exec> — the stream is empty (read 1
#     page(s)). Nothing wrote a stage record for this run.
#
# Every noun in that sentence belongs to the MANAGED-APP PIPELINE stream. Nothing
# writes a "stage record" to a container's stdout and nothing was ever going to,
# so the sentence describes a failure that cannot occur — a FINDING-SHAPED
# NON-FINDING, and it sends the reader to look for a missing pipeline writer
# that does not exist.
#
# ⛔ THE VOCABULARY WAS CHOSEN BY THE RENDERER AND BELONGS TO THE SOURCE. One
# `RunLogTail` type serves two streams on purpose (`cloud_log_page_to_run_log_
# tail`'s whole argument is that a second renderer is a second thing to keep in
# agreement). The fix is therefore NOT a second renderer: it is for the tail to
# CARRY which stream it is, and for the one renderer to speak that stream's
# language.
#
# ⚠ THE DEFAULT IS THE PIPELINE STREAM. A kind is a CLAIM the producer makes;
# a producer that makes none is the one this library was written for.
# =============================================================================
comptime RUN_LOG_STREAM_STAGE_RECORDS: Int = 0
"""A managed-app RUN's stage-record stream (`.../apps/runs/{r}/logs`). Records
are written by the pipeline manager, `next_cursor` is a real `?after=` cursor,
and "nothing wrote a stage record" IS the diagnosis when it is empty."""

comptime RUN_LOG_STREAM_CONTAINER_STDOUT: Int = 1
"""A terminated container's STDOUT, read out of a cloud logging provider
(`CloudLogSource`). ⛔ There are no stage records here and there never were:
the lines are whatever the process printed. An empty read is USUALLY the
provider's INGESTION LAG, not an empty stream — see the renderer."""


# =============================================================================
# ★★ THE CREDIBLE FLOOR — ONE DEFINITION, TWO READERS.
#
# ⛔ BOTH THE **WAITER** AND THE **RENDERER** MUST SEE IT. `komira_cloud_logs`'s
# `container_log_should_settle` consults it to decide whether to wait again; the
# RENDERER — the only party the operator actually reads — must say the same
# thing, and `komira_cloud_logs` depends on THIS package, not the other way
# round. Otherwise the tool makes a credibility judgement and then prints a
# report that does not contain it: a reader of `(2 page(s), done=true)` over one
# row could not learn that the tool had classed that read as not-yet-ingested.
#
# ⚠ AND THE ALTERNATIVE IS DRIFT. A second `= 2` beside the renderer is two
# numbers that must agree by hand. The constant belongs with the STREAM KIND it
# is about, and the stream kind is already here.
# =============================================================================
comptime CONTAINER_LOG_CREDIBLE_FLOOR: Int = 2
"""Below how many entries a COMPLETED container read is treated as not-yet-
ingested — by the WAITER (`container_log_should_settle`) and by the RENDERER
(`render_run_log_tail`'s short-read sentence) alike.

⚠ IT IS A FLOOR ON CREDIBILITY, NOT ON EMPTINESS, and `0` would be the wrong
value. A read taken mid-ingestion can return exactly ONE line — a real entry,
from a real container, and still not the answer. A run-to-completion container that
FAILED prints more than one line essentially always (a validator prints its rows
AND a `VERDICT:`; a crashing binary prints an error AND a trace), so a stream
that claims to END at zero or one entry is far likelier mid-ingestion than
complete."""


comptime RUN_LOG_REDACTED: String = "[REDACTED]"
"""What `redact_secretish` substitutes for a credential-shaped run. Deliberately
loud: a redaction an operator cannot see is a diagnosis they will make wrongly."""


# =============================================================================
# §1 — RunLogRecord — ONE stage record. Flat POD.
# =============================================================================
@fieldwise_init
struct RunLogRecord(Copyable, Movable, Deinitable):
    """One line of a run's stage log: the five allow-listed fields and nothing
    else.

      * `seq`     — the monotonic cursor. `next_cursor` for the following page is
                    the max `seq` on this one.
      * `ts`      — emit time, microseconds since epoch (the emitter's unit).
      * `level`   — the writer's level token (`info` / `error` / ...).
      * `step`    — the PIPELINE STAGE this line belongs to (`build` / `stage` /
                    `provision` / `deploy`). This is the field that answers
                    "which stage failed", which is the question the operator had.
      * `message` — the line itself.
    """

    var seq: Int
    var ts: Int
    var level: String
    var step: String
    var message: String

    @staticmethod
    def empty() -> RunLogRecord:
        return RunLogRecord(0, 0, String(""), String(""), String(""))


# =============================================================================
# §2 — RunLogTail — a run's log stream as this library read it.
# =============================================================================
@fieldwise_init
struct RunLogTail(Copyable, Movable, Deinitable):
    """What ONE `fetch_run_log_tail` produced.

      * `run_id`      — the run the records belong to, as the route reported it.
      * `records`     — the stage records, OLDEST -> NEWEST, already bounded by
                        the caller's cap (see `dropped_older`).
      * `next_cursor` — the cursor to pass as the next `?after=`.
      * `done`        — the route's own `done` (terminal run AND nothing new).
      * `pages`       — how many pages were read. Stated because "I read one page
                        and stopped" and "I drained the stream" are different
                        claims and only one of them is usually true.
      * `settles`     — how many BOUNDED WAITS the read spent before it accepted
                        its answer (`read_container_output_settled`). ⛔ NOT
                        decoration and NOT the same question as `pages`: pages
                        says how much of the stream was walked, settles says
                        WHETHER THE TOOL WAITED FOR INGESTION and how long. An
                        operator reading "0 row(s), 1 page, done=true" cannot
                        tell a tool that gave the provider ten seconds from one
                        that asked once at T+0 and believed the answer — and the
                        second one is the defect this field makes visible.
                        ZERO on the stage stream, which
                        has no settle.
      * `dropped_older` — records that WERE read and were then dropped off the
                        FRONT to honour the cap. Non-zero is a truncation the
                        renderer must say out loud.
      * `fetch_error` — EMPTY on success. Non-empty means the fetch or the parse
                        failed and `records` is not an answer.

    ⛔ `fetch_error` NEVER CARRIES A RESPONSE BODY — see the module header. It
    carries a status, a byte count, a position, a transport message. Never bytes
    the server chose."""

    var run_id: String
    var records: List[RunLogRecord]
    var next_cursor: Int
    var done: Bool
    var pages: Int
    # ★★ THE WAITS THIS READ SPENT. See the field docs above; it is
    # a SECOND quantity, not a refinement of `pages`.
    var settles: Int
    var dropped_older: Int
    var fetch_error: String
    # ★★ WHICH STREAM THIS IS. `RUN_LOG_STREAM_STAGE_RECORDS` by default. It
    # exists because only the SOURCE knows the stream's VOCABULARY, so the
    # renderer must not choose it — see the block above the constants.
    var stream_kind: Int

    @staticmethod
    def empty() -> RunLogTail:
        """A successful read that returned NO records — the ordinary state of a
        run nobody has written a stage record for yet. Distinct from a failure:
        `fetch_error` is empty, so the renderer says "no stage records" rather
        than "could not read"."""
        return RunLogTail(
            String(""),
            List[RunLogRecord](),
            0,
            False,
            0,
            0,
            0,
            String(""),
            RUN_LOG_STREAM_STAGE_RECORDS,
        )

    @staticmethod
    def failed(reason: String) -> RunLogTail:
        """A tail that could NOT be read. `reason` is a status/transport/parse
        statement — ⛔ never a response body."""
        return RunLogTail(
            String(""),
            List[RunLogRecord](),
            0,
            False,
            0,
            0,
            0,
            reason.copy(),
            RUN_LOG_STREAM_STAGE_RECORDS,
        )

    def ok(self) -> Bool:
        """True iff the read produced an answer (whether or not it had records)."""
        return len(self.fetch_error.as_bytes()) == 0

    def is_empty(self) -> Bool:
        """True iff this is a successful read with nothing in it."""
        return self.ok() and len(self.records) == 0


# =============================================================================
# §3 — the scanner primitives.
# =============================================================================
def _is_space(c: UInt8) -> Bool:
    return (
        c == UInt8(ord(" "))
        or c == UInt8(ord("\t"))
        or c == UInt8(ord("\n"))
        or c == UInt8(ord("\r"))
    )


def _skip_space(b: Span[UInt8, _], i: Int) -> Int:
    var j = i
    while j < len(b) and _is_space(b[j]):
        j += 1
    return j


def _scan_string(b: Span[UInt8, _], i: Int, mut out: String) -> Int:
    """Read a JSON string starting AT its opening quote (`b[i] == '"'`), writing
    the UNESCAPED value into `out`.

    Returns the index just after the closing quote, or -1 if the string is
    unterminated (in which case `out` is not an answer). Handles exactly the
    escapes the emitter produces (`\\"` `\\\\` `\\n` `\\r` `\\t`); any other
    `\\x` passes `x` through, which is the conservative choice — this is a
    diagnostic renderer, not a validator.

    ⚠ AN OUT-PARAM RATHER THAN A TUPLE, deliberately: a `(String, Int)` return
    forces a copy of every scanned value at every call site, and this scanner
    runs once per field of every record of every page.

    ⛔ IT ACCUMULATES **BYTES**, NEVER `chr(Int(byte))` — see the block comment
    above `_lower`. Of the two places where that matters this is the more
    damaging one: it is on the PRIMARY parse path, so a transcoding bug here
    would mangle every `RunLogRecord.message` on the way IN, before any
    renderer or redactor saw it. `chr` maps a CODEPOINT to UTF-8, so each raw byte of a
    multi-byte character came back out as its own two-byte character and the
    text was already mojibake by the time it was stored.

    ⚠ THE ESCAPE ARM IS THE SAME BUG WITH A SECOND FACE: a JSON `\\uXXXX` — which
    this scanner does not decode and deliberately passes through — arrives here
    as the bytes `u`, `X`, `X`, `X`, `X`, and a byte-preserving pass-through
    keeps them intact where a `chr` round trip does not.

    The buffer is converted ONCE at each exit, which is also strictly less work
    than N String appends."""
    out = String()
    if i >= len(b) or b[i] != UInt8(ord('"')):
        return -1
    var buf = List[UInt8]()
    var j = i + 1
    while j < len(b):
        var c = b[j]
        if c == UInt8(ord('"')):
            out = String(unsafe_from_utf8=Span(buf))
            return j + 1
        if c == UInt8(ord("\\")):
            if j + 1 >= len(b):
                return -1
            var e = b[j + 1]
            if e == UInt8(ord("n")):
                buf.append(UInt8(0x0A))
            elif e == UInt8(ord("r")):
                buf.append(UInt8(0x0D))
            elif e == UInt8(ord("t")):
                buf.append(UInt8(0x09))
            else:
                buf.append(e)
            j += 2
            continue
        buf.append(c)
        j += 1
    return -1


def _scan_number(b: Span[UInt8, _], i: Int, mut out: Int) -> Int:
    """Read a bare JSON integer at `i` into `out`. Returns the index just after
    it, or -1 when there is no digit there. Fractions/exponents are not produced
    by the emitter; a `.` simply ends the integer part."""
    out = 0
    var j = i
    var neg = False
    if j < len(b) and b[j] == UInt8(ord("-")):
        neg = True
        j += 1
    var start = j
    var v = 0
    while j < len(b) and b[j] >= UInt8(ord("0")) and b[j] <= UInt8(ord("9")):
        v = v * 10 + Int(b[j] - UInt8(ord("0")))
        j += 1
    if j == start:
        return -1
    out = -v if neg else v
    return j


def _skip_value(b: Span[UInt8, _], i: Int) -> Int:
    """Skip ONE JSON value at `i` (the NOT-allow-listed branch). Returns the index
    after it, or -1 if it cannot be skipped. Nested objects/arrays are skipped by
    depth, tracking string state so a brace inside a string does not count."""
    var j = _skip_space(b, i)
    if j >= len(b):
        return -1
    var c = b[j]
    if c == UInt8(ord('"')):
        var scratch = String()
        return _scan_string(b, j, scratch)
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        var depth = 0
        while j < len(b):
            var d = b[j]
            if d == UInt8(ord('"')):
                var scratch2 = String()
                var nx = _scan_string(b, j, scratch2)
                if nx < 0:
                    return -1
                j = nx
                continue
            if d == UInt8(ord("{")) or d == UInt8(ord("[")):
                depth += 1
            elif d == UInt8(ord("}")) or d == UInt8(ord("]")):
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return -1
    # a bare literal: number / true / false / null — run to the next , } ] or space
    while j < len(b):
        var d = b[j]
        if (
            d == UInt8(ord(","))
            or d == UInt8(ord("}"))
            or d == UInt8(ord("]"))
            or _is_space(d)
        ):
            return j
        j += 1
    return j


# =============================================================================
# §4 — the ALLOW-LISTED object parse.
# =============================================================================
def _parse_line_object(
    b: Span[UInt8, _], start: Int, mut rec: RunLogRecord
) -> Int:
    """Parse ONE `lines[]` object beginning at its `{` into `rec`. Returns the
    index just after the closing brace, or -1 on a malformed object (in which
    case `rec` is not an answer).

    ★ THE ALLOW-LIST LIVES HERE. The walk is over KEY/VALUE PAIRS — key string,
    `:`, value — so it is structural: a `message` whose text contains
    `"step":"deploy"` is a VALUE and is never mistaken for a key. A key outside
    `RUN_LOG_FIELD_ALLOWLIST` has its value SKIPPED by `_skip_value` and is
    dropped on the floor."""
    rec = RunLogRecord.empty()
    var j = _skip_space(b, start)
    if j >= len(b) or b[j] != UInt8(ord("{")):
        return -1
    j += 1
    var key = String()
    var sval = String()
    var ival = 0
    while True:
        j = _skip_space(b, j)
        if j >= len(b):
            return -1
        if b[j] == UInt8(ord("}")):
            return j + 1
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var kend = _scan_string(b, j, key)
        if kend < 0:
            return -1
        j = _skip_space(b, kend)
        if j >= len(b) or b[j] != UInt8(ord(":")):
            return -1
        j = _skip_space(b, j + 1)
        if key == String("seq"):
            var ne = _scan_number(b, j, ival)
            if ne < 0:
                return -1
            rec.seq = ival
            j = ne
        elif key == String("ts"):
            var te = _scan_number(b, j, ival)
            if te < 0:
                return -1
            rec.ts = ival
            j = te
        elif key == String("level"):
            var le = _scan_string(b, j, sval)
            if le < 0:
                return -1
            rec.level = sval.copy()
            j = le
        elif key == String("step"):
            var se = _scan_string(b, j, sval)
            if se < 0:
                return -1
            rec.step = sval.copy()
            j = se
        elif key == String("message"):
            var me = _scan_string(b, j, sval)
            if me < 0:
                return -1
            rec.message = sval.copy()
            j = me
        else:
            # ⛔ NOT ALLOW-LISTED. Skipped, not stored — see the module header.
            var nj = _skip_value(b, j)
            if nj < 0:
                return -1
            j = nj


def _find_key(body: String, b: Span[UInt8, _], key: String) -> Int:
    """Index just after the `"<key>":` of a TOP-LEVEL key, or -1.

    Deliberately a scan (the `_json_string_field` convention): the top-level keys
    of this body are `run_id` / `lines` / `next_cursor` / `done`, none of which
    can appear as a top-level key twice. It is used ONLY for those — never for a
    record field, where the structural walk above is what runs."""
    var needle = String('"') + key + String('"')
    var idx = body.find(needle)
    if idx < 0:
        return -1
    var j = _skip_space(b, idx + len(needle.as_bytes()))
    if j >= len(b) or b[j] != UInt8(ord(":")):
        return -1
    return _skip_space(b, j + 1)


def parse_run_logs_body(body: String, run_id_hint: String) -> RunLogTail:
    """Parse a `GET .../runs/{r}/logs` 200 body into a `RunLogTail`.

    ⛔ ON A PARSE FAILURE THE BODY IS NOT ECHOED. The returned `fetch_error`
    states the byte length and where the scan stopped, and nothing else — see the
    module header for why that rule is absolute here.

    `run_id_hint` is what the caller ASKED for; the parsed `run_id` wins when the
    body carries one, so a mismatch is visible rather than papered over."""
    var b = body.as_bytes()
    var tail = RunLogTail.empty()
    tail.run_id = run_id_hint.copy()

    var scratch = String()
    var rid = _find_key(body, b, String("run_id"))
    if rid >= 0:
        if _scan_string(b, rid, scratch) >= 0:
            tail.run_id = scratch.copy()

    var li = _find_key(body, b, String("lines"))
    if li < 0:
        return RunLogTail.failed(
            String("the 200 body has no `lines` array (")
            + String(len(b))
            + String(" bytes read; body NOT echoed)")
        )
    var j = _skip_space(b, li)
    if j >= len(b) or b[j] != UInt8(ord("[")):
        return RunLogTail.failed(
            String("`lines` is not an array at byte ")
            + String(j)
            + String(" of ")
            + String(len(b))
            + String(" (body NOT echoed)")
        )
    j += 1
    while True:
        j = _skip_space(b, j)
        if j >= len(b):
            return RunLogTail.failed(
                String("unterminated `lines` array after ")
                + String(len(tail.records))
                + String(" record(s), at byte ")
                + String(j)
                + String(" of ")
                + String(len(b))
                + String(" (body NOT echoed)")
            )
        if b[j] == UInt8(ord("]")):
            j += 1
            break
        if b[j] == UInt8(ord(",")):
            j += 1
            continue
        var rec = RunLogRecord.empty()
        var oend = _parse_line_object(b, j, rec)
        if oend < 0:
            return RunLogTail.failed(
                String("malformed log-line object at byte ")
                + String(j)
                + String(" of ")
                + String(len(b))
                + String(", after ")
                + String(len(tail.records))
                + String(" good record(s) (body NOT echoed)")
            )
        tail.records.append(rec^)
        j = oend

    var nc = _find_key(body, b, String("next_cursor"))
    if nc >= 0:
        var cur = 0
        if _scan_number(b, nc, cur) >= 0:
            tail.next_cursor = cur
    # A body with records but no `next_cursor` still has one: the max seq read.
    if len(tail.records) > 0 and tail.next_cursor == 0:
        tail.next_cursor = tail.records[len(tail.records) - 1].seq

    var dn = _find_key(body, b, String("done"))
    if dn >= 0 and dn < len(b) and b[dn] == UInt8(ord("t")):
        tail.done = True

    tail.pages = 1
    return tail^


# =============================================================================
# §5 — redaction (DEFENCE IN DEPTH, not the boundary).
# =============================================================================
# ⛔⛔ EVERY SCANNER IN THIS FILE REBUILDS A STRING BYTE BY BYTE, AND THEY MUST DO
# IT BY APPENDING **BYTES** — NEVER `chr(Int(byte))`. (Three sites: `_scan_string`
# above, and `_lower` / `_redact_after` below.)
#
# `chr(n)` maps a UNICODE CODEPOINT to its UTF-8 encoding. Feeding it a raw byte
# of a multi-byte character re-encodes that byte as a codepoint in its own right:
# the `0xE2` that opens `★` (U+2605, `E2 98 85`) comes back out as the TWO bytes
# of U+00E2 (`Ã¢`), and every non-ASCII character in the message is mangled into
# three mojibake characters: `redact_secretish("★")` would return `Ã¢..` — a
# byte-preserving no-op becomes a lossy transcode for every input operator-facing
# prose produces (`⛔ ★ — …` are in nearly every operator-facing sentence we
# write), and `render_run_log_tail` puts EVERY run-log message through it.
#
# ★ IT IS ALSO SILENT IN EXACTLY THE PLACE THAT MATTERS. The redaction still
# happens, the surrounding ASCII still reads correctly, and the corruption only
# touches the decorative characters — so the output looks "mostly fine" in the
# one place nobody re-reads: an operator's terminal during a failed deploy.
#
# The fix is to accumulate into a `List[UInt8]` and convert ONCE
# (`String(unsafe_from_utf8=...)`, the byte-oriented idiom this file's own
# `_scan_string` already uses). That is also strictly less work than N String
# appends.
def _lower(s: String) -> String:
    """An ASCII-only case fold used ONLY as a search haystack. Byte-preserving:
    every non-`A`-`Z` byte rides through untouched, so `hb[i]` and `sb[i]` index
    the SAME position in `_redact_after` — an invariant a transcoding fold would
    break as well as corrupting the text."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out.append(c + UInt8(32))
        else:
            out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _redact_after(s: String, marker_lower: String, stop_at_quote: Bool) -> String:
    """Replace the run of characters following each occurrence of `marker_lower`
    (matched case-insensitively) with `RUN_LOG_REDACTED`. The run ends at
    whitespace, or — when `stop_at_quote` — at the next `"`.

    ⛔ BYTE-PRESERVING — see the block comment above this function. The markers
    are all ASCII and the run boundaries are all ASCII (whitespace, `"`), so the
    SCAN needs no codepoint awareness; the OUTPUT does, and it gets it by never
    decoding in the first place."""
    var hay = _lower(s)
    var hb = hay.as_bytes()
    var sb = s.as_bytes()
    var mb = marker_lower.as_bytes()
    if len(mb) == 0 or len(mb) > len(sb):
        return s.copy()
    var out = List[UInt8]()
    var redacted = RUN_LOG_REDACTED.as_bytes()
    var i = 0
    while i < len(sb):
        var hit = False
        if i + len(mb) <= len(hb):
            hit = True
            for k in range(len(mb)):
                if hb[i + k] != mb[k]:
                    hit = False
                    break
        if not hit:
            out.append(sb[i])
            i += 1
            continue
        for k in range(len(mb)):
            out.append(sb[i + k])
        var j = i + len(mb)
        var start = j
        while j < len(sb):
            var c = sb[j]
            if _is_space(c):
                break
            if stop_at_quote and c == UInt8(ord('"')):
                break
            j += 1
        if j > start:
            for k in range(len(redacted)):
                out.append(redacted[k])
        i = j
    return String(unsafe_from_utf8=Span(out))


def redact_secretish(s: String) -> String:
    """Scrub credential-SHAPED runs out of a message before it is printed.

    ⛔ THIS IS NOT THE SECURITY BOUNDARY — the field allow-list and the
    never-echo-a-body rule are (module header). This is the net under them, for
    the case where an upstream writer put a token into a `message` it should not
    have. Three shapes, chosen because they are what our own deploy code and the
    HTTP clients around it actually emit:

        Bearer <run>        ->  Bearer [REDACTED]
        token=<run>         ->  token=[REDACTED]
        "token":"<run>"     ->  "token":"[REDACTED]"

    Matched case-insensitively. It is deliberately narrow: a wide heuristic that
    mangles ordinary diagnostics makes operators stop reading the output, which
    costs more than it saves."""
    var out = _redact_after(s, String("bearer "), False)
    out = _redact_after(out^, String("token="), False)
    out = _redact_after(out^, String('token":"'), True)
    return out^


# =============================================================================
# §6 — the BOUNDED renderer.
# =============================================================================
comptime DEFAULT_MAX_RENDERED_RECORDS: Int = 40
"""How many records the failure report prints by default. The LAST 40 — a failing
stage's own output is at the END of the stream. Bounded because an operator
drowning in output is a different failure from an operator with no output."""

comptime DEFAULT_MAX_MESSAGE_BYTES: Int = 400
"""Per-message ceiling. A single record can be a whole stack trace; 40 of them
unbounded is a screenful of scrollback nobody reads."""


def utf8_clip_end(s: String, max_bytes: Int) -> Int:
    """THE ONLY END A BYTE-CEILED SLICE OF `s` MAY BE GIVEN: the largest offset
    `<= max_bytes` that is a UTF-8 CODEPOINT BOUNDARY.

    ⛔ `s[byte=0:n]` ASSERTS that `n` is a boundary, and a Mojo assert ABORTS THE
    PROCESS — it is not an exception a caller can absorb. Whether a fixed ceiling
    lands inside a character is a property of the UPSTREAM TEXT, so a call site
    that skips this walk-back is not merely wrong on strange input: it is
    INTERMITTENT, green on the run that measures it and fatal on the next. Our
    own prose is dense with multi-byte characters (⛔ ★ — ⚠ ⇒), which is what
    makes every ceiling in this tree reachable.

    ★ IT IS PUBLIC, AND THAT IS THE POINT. A walk-back copy-pasted into each
    module is one the next site that needs it does not get, and the abort
    ships again. A safety primitive that must be re-derived at every call site
    will eventually not be.
    Callers keep their OWN clip SENTENCE — the wording differs per site and
    always will; what may not differ is where the cut lands.

    ⚠ THE RETURNED COUNT IS THE ONE TO REPORT. A remainder counted against the
    REQUESTED ceiling rather than this ACTUAL cut is a second, quieter lie in the
    same sentence — the report would claim bytes it did not keep.

    The walk is over CONTINUATION bytes (`0b10xxxxxx`), of which UTF-8 guarantees
    at most three, so it terminates and clips SHORT rather than mid-character."""
    var b = s.as_bytes()
    var n = len(b)
    if max_bytes >= n:
        return n
    if max_bytes <= 0:
        return 0
    var cut = max_bytes
    while cut > 0 and (Int(b[cut]) & 0xC0) == 0x80:
        cut -= 1
    return cut


def _clip(s: String, max_bytes: Int) -> String:
    """Clip a message to `max_bytes`, SAYING how much was cut. A silent clip is a
    truncated stack trace that reads like a complete one.

    ⛔ THE CEILING IS A BYTE COUNT AND THE INPUT IS UTF-8, SO THE CUT MUST BE
    WALKED BACK TO A CODEPOINT BOUNDARY. `s[byte=0:n]` ASSERTS that `n` is one,
    and an assert in Mojo ABORTS THE PROCESS — it is not an exception a caller
    can absorb:

        Assert Error: String slice ends on, 400
        which is not a codepoint boundary.  ->  the process dies on signal 4.

    ★ AND THE BLAST RADIUS IS NOT THE REPORT. A caller that DEPLOYS an
    ephemeral app and DELETES it at the end can abort between those two, and a
    killed process runs no destructor, so the run leaves a live service behind.
    A render helper takes down the teardown, and the operator sees a stack dump
    instead of any row.

    ⚠ IT IS INTERMITTENT BY CONSTRUCTION: whether byte `max_bytes` lands inside
    a character is a property of the UPSTREAM TEXT, so two executions of the
    same binary can differ. Log prose dense with multi-byte characters
    (⛔ ★ — …) makes it reachable from the first message that runs long.

    The walk-back is over CONTINUATION bytes (`0b10xxxxxx`), of which UTF-8
    guarantees at most three, so it terminates and clips SHORT rather than
    mid-character. The remainder count is reported against the ACTUAL cut, not
    the requested ceiling — a byte total that disagreed with the bytes kept would
    be a second, quieter lie in the same sentence."""
    var b = s.as_bytes()
    if max_bytes <= 0 or len(b) <= max_bytes:
        return s.copy()
    var cut = utf8_clip_end(s, max_bytes)
    var head = String(s[byte=0:cut])
    return (
        head
        + String(" … [message clipped: ")
        + String(len(b) - cut)
        + String(" more byte(s)]")
    )


def _stream_noun(tail: RunLogTail) -> String:
    """What this stream's records ARE, in the SOURCE's own vocabulary."""
    if tail.stream_kind == RUN_LOG_STREAM_CONTAINER_STDOUT:
        return String("container output")
    return String("stage records")


def _read_extent_clause(tail: RunLogTail) -> String:
    """HOW MUCH OF THE STREAM THIS READ COVERED — the clause that separates
    "I drained it" from "I read page 1 of N".

    ⛔ IT IS ONE FUNCTION BECAUSE BOTH BRANCHES NEED IT. A RECORDS branch that
    prints `pages` + `next_cursor` + `done` beside an EMPTY branch that prints
    `pages` alone is exactly backwards. `done` is the
    only field that separates *the stream is genuinely empty* from *page 1 of N
    happened to be empty*, and the EMPTY branch is the one that needs that
    distinction most.

    ⚠ `next_cursor` IS PRINTED FOR THE STAGE STREAM ONLY, and that is not a
    cosmetic narrowing. It is the run-log route's real `?after=` cursor there; on
    a container stream nothing sets it, so printing `next_cursor=0` would put a
    number that means nothing next to two that mean something — and the
    continuation a cloud provider actually returns is an opaque STRING token this
    POD has no field for (`CloudLogPage.next_token`, folded into `done`)."""
    var out = String("(") + String(tail.pages) + String(" page(s)")
    if tail.stream_kind == RUN_LOG_STREAM_STAGE_RECORDS:
        out += String(", next_cursor=") + String(tail.next_cursor)
    else:
        # ★★ THE WAITS, ON THE CONTAINER STREAM ONLY — narrowed for
        # the SAME reason `next_cursor` is narrowed the other way: the stage
        # stream has no settle, so `settles=0` there would be a number that means
        # nothing printed next to two that mean something. On THIS stream it is
        # the number that separates "the tool waited for ingestion and this is
        # what arrived" from "the tool asked once at T+0 and believed the
        # answer" — and without this line no report could tell them apart.
        out += String(", ") + String(tail.settles) + String(" settle(s)")
    out += String(", done=") + (
        String("true") if tail.done else String("false")
    )
    out += String(")")
    return out^


def _next_action_lead(tail: RunLogTail) -> String:
    """THE REMEDY ITSELF — which command, WHEN to run it, and WHY.

    ⛔ IT IS ITS OWN FUNCTION BECAUSE THE TWO BRANCHES ARE TWO DIFFERENT PIECES
    OF ADVICE, and one string cannot carry both without contradicting itself. A
    single `var out` assigned in each arm would also draw the compiler's
    "assignment never used" warning, so the shape
    that removes the contradiction and the shape that removes the warning are
    the same shape."""
    if tail.done:
        # The provider said the stream ENDS here. A short or empty answer is
        # then either a genuinely short stream or a read taken before ingestion
        # caught up — and TIME is the only thing that distinguishes them.
        return String(
            " ⇒ NEXT: re-run THIS gate alone ONCE INGESTION HAS CAUGHT UP —"
            " the validate step with `--only-validate=step:<step>`"
            " (the step name is on the line above) — which re-reads this same"
            " stream at a LATER T. ⛔ A raw cloud CLI is neither the remedy nor"
            " needed here: THIS read is the tool that replaces one."
        )
    # A continuation token is OUTSTANDING: the read stopped on its own bound
    # while the provider still held stream. Waiting cannot produce what is
    # already there.
    return String(
        " ⇒ NEXT: RE-READ this stream NOW —"
        " the validate step with `--only-validate=step:<step>`"
        " (the step name is on the line above). ⛔ NOT 'wait for ingestion':"
        " this read stopped on its OWN bound with the provider still holding"
        " stream, so a LATER T is not what is missing — a SECOND READ is. ⛔ A"
        " raw cloud CLI is neither the remedy nor needed here: THIS read is the"
        " tool that replaces one."
    )


def _next_action_sentence(tail: RunLogTail) -> String:
    """★★ WHAT TO DO NEXT, FOR A CONTAINER READ THAT CAME BACK EMPTY OR SHORT.

    ── ⛔ WHY IT EXISTS ─────────────────────────────────────────────────────────
    A diagnostic that reports an absence and stops has handed the reader a dead
    end. *"Found nothing to look for"* and *"found nothing"* are the same
    output, and neither is ever a pass.

    ⛔ IT NAMES NO RAW CLOUD COMMAND, DELIBERATELY. The operator's remedy is a
    `komira_ci` command, not a raw `gcloud` or `aws` one: THIS read is the tool
    that replaces those, and printing one here would undo that.

    ⛔ AND IT DOES NOT NAME THE VALIDATION RECORD. The record carries the step's
    VERDICT plus its `detail` block; on the in-cloud arm `detail` is the POINTER
    at the stream, not the rows. Sending a reader to an artifact that does not
    contain what they are looking for is the same finding-shaped non-finding
    this renderer exists to avoid.

    ⚠ IT IS DELIBERATELY SHAPE-ONLY. This library knows the STREAM; it does not
    know the app, the env or the step name, and inventing plausible values for
    them would print a command that does not run. The caller's own report names
    all three, on the lines above this block."""
    if tail.stream_kind != RUN_LOG_STREAM_CONTAINER_STDOUT:
        return String("")
    # ★★ THE REMEDY BRANCHES ON `done`. Without that, this block contradicts
    # itself in one paragraph: a lead saying *"re-run THIS gate alone once
    # ingestion has caught up … which re-reads this same stream at a later T"*
    # beside a clause saying *"no amount of waiting produces it and a re-read is
    # what fetches it."* Both cannot be the advice. An operator reading the
    # first one waits for data that is ALREADY on the provider.
    #
    # ⛔ THE DISCRIMINATOR IS `done`, AND IT IS THE ONLY ONE THERE IS. A
    # continuation token outstanding (`done=false`) means the read stopped on ITS
    # OWN bound while the provider still had stream — waiting changes nothing and
    # a SECOND READ is the whole remedy. `done=true` means the provider said the
    # stream ENDS here, so a short answer is either genuinely short or taken
    # before ingestion caught up — and there, TIME is the remedy.
    #
    # ⚠ THE COMMAND IS THE SAME IN BOTH BRANCHES ON PURPOSE. What changes is WHEN
    # to run it and WHY, which is the part the operator must not be told wrongly.
    var out = _next_action_lead(tail)
    if tail.done and tail.settles == 0:
        # ⚠ ZERO SETTLES ON A `done=true` SHORT/EMPTY READ IS ITS OWN FINDING —
        # and it is the one a reader is least equipped to spot.
        #
        # ⛔ THE `tail.done` GUARD IS LOAD-BEARING, NOT A TIGHTENING. Spending no
        # settle is a DECISION `container_log_should_settle` makes, and on
        # `done=false` it is the RIGHT one: a continuation token is outstanding,
        # so there is demonstrably more RIGHT NOW and waiting for more to arrive
        # answers a question nobody asked. Warning there would manufacture a
        # finding out of the policy working — the finding-shaped non-finding this
        # renderer exists to avoid (`_empty_stream_sentence`).
        # With `done=true` the provider said the stream ENDS here, so a zero-wait
        # short read is either a genuinely short stream or a read issued before
        # ingestion caught up, and the report must not silently assume the first.
        out += String(
            " ⚠ AND THIS READ SPENT **NO** SETTLE: the provider reported the"
            " stream as ENDED and the tool waited zero seconds for ingestion."
            " For a container that has only just died that is the shape of a"
            " read taken before its lines landed."
        )
    elif not tail.done:
        # ⚠ THE OTHER DIRECTION, AND IT NEEDS ITS OWN SENTENCE. `done=false` says
        # the walk stopped on ITS OWN bound with the stream still going — so the
        # remedy is not to wait, and saying "wait and re-run" alone would send a
        # reader to buy time that will not help.
        out += String(
            " ⚠ AND THIS READ DID NOT REACH THE END OF THE STREAM: it stopped on"
            " its own page/row bound with a continuation token outstanding, so"
            " what is missing is ALREADY THERE — no amount of waiting produces"
            " it and a re-read is what fetches it."
        )
    return out^


def _short_read_sentence(tail: RunLogTail, rows_read: Int) -> String:
    """★★ A READ THE TOOL ITSELF CLASSED AS NOT-YET-INGESTED, SAID OUT LOUD.

    ── ⛔ THE GAP THIS CLOSES ─────────────────────────────────────────────────
    `container_log_should_settle` judges a completed container read of fewer
    than `CONTAINER_LOG_CREDIBLE_FLOOR` entries to be mid-ingestion. Without
    this sentence the operator's report says NOTHING about that judgement: a
    one-line read renders through the ordinary RECORDS branch as `showing 1
    record(s)`, indistinguishable from a container that printed one line and
    stopped.

    ⇒ A tool that knows a number is probably not the answer, and prints it as if
      it were, is the fail-quiet the settle was built to remove, one layer up.

    ⛔ IT DOES NOT SUPPRESS THE ROWS AND IT DOES NOT CHANGE A VERDICT. Whatever
    came back is still printed — a short read is very often the only evidence
    there is. This adds the sentence that stops it from being read as complete.

    EMPTY for the stage stream (no ingestion lag, no settle) and for any read at
    or above the floor."""
    if tail.stream_kind != RUN_LOG_STREAM_CONTAINER_STDOUT:
        return String("")
    if rows_read >= CONTAINER_LOG_CREDIBLE_FLOOR:
        return String("")
    return (
        String("\n  run-log: ⚠ SHORT READ — ")
        + String(rows_read)
        + String(" row(s) is BELOW this stream's credible floor of ")
        + String(CONTAINER_LOG_CREDIBLE_FLOOR)
        + String(
            ", so the tool's own settle policy classed this read as"
            " mid-ingestion rather than complete. A run-to-completion container"
            " that FAILED prints more than one line essentially always (rows"
            " AND a VERDICT:; an error AND a trace), so treat the line(s) above"
            " as a PARTIAL view of what it printed."
        )
        + _next_action_sentence(tail)
    )


def _empty_stream_sentence(tail: RunLogTail) -> String:
    """A read that REACHED the source and got nothing — said in the SOURCE'S OWN
    WORDS.

    ── ⛔ THE DEFECT THIS PREVENTS ─────────────────────────────────────────────
    A single-vocabulary branch would print, over a Cloud Run container's STDOUT:

        run-log: NO STAGE RECORDS for run <exec> — the stream is empty (read 1
        page(s)). Nothing wrote a stage record for this run.

    Every noun there belongs to the managed-app PIPELINE stream. Nothing writes
    a "stage record" to a container's stdout, so the sentence names a failure
    that cannot occur — and a reader will believe it, even about a job that
    demonstrably printed rows. A finding-shaped non-finding is worse than
    silence: it sends a reader to look for a writer that does not exist.

    ── ★ AND THE CONTAINER ARM NAMES THE OVERWHELMINGLY LIKELY CAUSE ──────────
    A cloud logging provider INGESTS asynchronously and the deploy tool issues
    this read at T+0 the instant a step is decided STEP_FAIL. Seconds-to-a-minute
    of lag means an EMPTY FIRST READ IS THE EXPECTED RESULT for a container that
    has only just died — it is not evidence that the container printed nothing,
    and reading it as such is how "the validator printed no rows" gets diagnosed
    for a validator whose rows simply had not landed yet.

    ⛔ IT STILL DOES NOT CLAIM THE CONTAINER PRINTED SOMETHING. It states what
    was read, over how many pages, whether the stream ENDED there, and what
    an empty result does and does not prove. That is the whole difference."""
    var who = tail.run_id if len(
        tail.run_id.as_bytes()
    ) > 0 else String("(unnamed)")
    if tail.stream_kind == RUN_LOG_STREAM_CONTAINER_STDOUT:
        var out = (
            String("  run-log: NO CONTAINER OUTPUT read for ")
            + who
            # ★★ THE ROW COUNT, SAID AS A NUMBER. "NO CONTAINER
            # OUTPUT" is a word; `0 row(s)` is the measurement, and a report that
            # states only the word reads as prose a skimmer skips. The three
            # quantities that decide what this read MEANS — rows, pages, settles
            # — are on one line, in that order.
            + String(" — 0 row(s) ")
            + _read_extent_clause(tail)
            + String(
                ". ⚠ THIS IS NOT PROOF THE CONTAINER PRINTED NOTHING. The read"
                " is issued the moment the step is decided FAILED, and cloud"
                " logging ingests asynchronously — seconds to a minute behind a"
                " container that has just died — so an empty first read is the"
                " EXPECTED result for a just-terminated task."
            )
        )
        # ⚠ THE TWO `done` STATES ARE TWO DIFFERENT STATEMENTS AND MUST NOT SHARE
        # A SENTENCE. `done=false` says the provider HANDED BACK a continuation
        # token — there is more and this read did not reach it. `done=true` says
        # the provider reported the stream as ending here, which is the stronger
        # claim and the only one under which "nothing had been ingested" is the
        # whole answer. Printing the `done=false` explanation under `done=true`
        # is the same class of defect as the stage-record vocabulary on a
        # container stream: a true-sounding sentence about a
        # state the reader is not in.
        if not tail.done:
            out += String(
                " ⛔ AND THIS READ DID NOT REACH THE END: the provider handed"
                " back a continuation token, so there IS more of this stream"
                " than was read."
            )
        else:
            out += String(
                " The provider reported the stream as ENDING here, so as of"
                " this read nothing had been ingested for it."
            )
        out += _next_action_sentence(tail)
        return out^
    return (
        String("  run-log: NO STAGE RECORDS for run ")
        + who
        + String(" — the stream is empty ")
        + _read_extent_clause(tail)
        + String(". Nothing wrote a stage record for this run.")
    )


def render_run_log_tail(
    tail: RunLogTail,
    max_records: Int = DEFAULT_MAX_RENDERED_RECORDS,
    max_message_bytes: Int = DEFAULT_MAX_MESSAGE_BYTES,
) -> String:
    """Render a tail for an operator, BOUNDED, and stating every bound it applied.

    THE THREE STATES, and each one gets its own sentence — because they send the
    reader to three different places:

      * FETCH FAILED  -> ONE line naming the fault. ⛔ It does NOT and must not
        change the verdict of whatever was being reported; the caller keeps that.
      * NO RECORDS    -> an empty stream is an ANSWER, not an error, and
        rendering it as blank space is how a reader concludes the tool is
        broken. ⛔ WHICH answer it is depends on the STREAM, not on this
        function — see `_empty_stream_sentence`. A pipeline stream's emptiness
        means nobody wrote a stage record; a container stream's usually means
        the provider has not ingested yet.
      * RECORDS       -> a header naming the run and the bound, then the LAST
        `max_records` records oldest->newest, each clipped to
        `max_message_bytes`, each stating what was cut.

    ★ BOTH non-fault branches now print the SAME read-extent clause
    (`_read_extent_clause`). They did not: the records branch printed pages +
    cursor + `done` and the empty branch printed pages alone, which is exactly
    backwards — `done` is what separates "the stream is empty" from "page 1 of N
    was empty", and the empty branch is the one that needs it.

    Every message goes through `redact_secretish` on the way out."""
    var n = len(tail.records)
    if not tail.ok() and n == 0:
        return (
            String("  run-log: COULD NOT READ — ")
            + tail.fetch_error
            + String(" (this is an ENRICHMENT fault; the step verdict above")
            + String(" stands unchanged)")
        )
    if n == 0:
        return _empty_stream_sentence(tail)
    var cap = max_records if max_records > 0 else n
    var first = n - cap if n > cap else 0
    var omitted_here = first + tail.dropped_older
    var out = (
        String("  run-log for run ")
        + (tail.run_id if len(tail.run_id.as_bytes()) > 0 else String("(unnamed)"))
        + String(" — showing ")
        + String(n - first)
        + String(" record(s)")
    )
    if omitted_here > 0:
        out += (
            String(", the LAST of ")
            + String(n + tail.dropped_older)
            + String(" read; ")
            + String(omitted_here)
            + String(" OLDER record(s) omitted")
        )
    out += String(" ") + _read_extent_clause(tail)
    for i in range(first, n):
        var r = tail.records[i].copy()
        out += (
            String("\n    [")
            + String(r.seq)
            + String("] ")
            + (r.level if len(r.level.as_bytes()) > 0 else String("-"))
            + String(" ")
            + (r.step if len(r.step.as_bytes()) > 0 else String("-"))
            + String(": ")
            + _clip(redact_secretish(r.message), max_message_bytes)
        )
    if not tail.ok():
        # ★ A PARTIAL READ IS REPORTED AS PARTIAL. Records were obtained and then
        # the stream stopped answering; printing them silently would claim the
        # tail is complete, and printing nothing would throw away the half that
        # is usually the half that explains the failure.
        out += (
            String("\n  run-log: the read was CUT SHORT after ")
            + String(tail.pages)
            + String(" page(s) — ")
            + tail.fetch_error
            + String(" (the records above are what was obtained; the step")
            + String(" verdict stands unchanged)")
        )
    else:
        # ★★ A READ THE SETTLE POLICY ITSELF CALLED NOT-CREDIBLE, SAID OUT LOUD.
        # ⛔ ONLY ON A CLEAN READ: a read CUT SHORT by a fault is
        # short because of the fault, and the line above already names it. Adding
        # "this is probably ingestion lag" there would offer a second, wrong
        # cause for an effect that already has a stated one.
        out += _short_read_sentence(tail, n + tail.dropped_older)
    return out^
