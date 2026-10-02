# =============================================================================
# kci_deploy/validate.mojo -- the DEPLOY-AND-VALIDATE loop of the deploy
#   library: apply -> poll until converged -> run validators -> poll until PASS
#   -> report.
# =============================================================================
#
# `deploy_apply` converges a graph, but a converged intent ledger is not a
# converged system. This file adds the gates that turn "apply succeeded" into
# "the deploy is healthy and validated":
#   * poll_until_converged -- polls every node's LIVE `read_status` (the only
#     actual-state source) until the graph SETTLES: no node still CONVERGING and
#     none FAILED. A service mid-rollout is waited out (bounded) instead of
#     declaring victory on the apply alone.
#   * run_validation_gate / run_all_validation_gates -- run a `Validator`
#     repeatedly until it emits PASS, or the budget is exhausted. A freshly
#     converged service may fail an end-to-end validator for a few seconds.
#   * run_validation_dag -- the parallel step scheduler: steps with declared
#     dependencies, per-step budgets, bounded retries, and a teardown of every
#     step's cloud resources on every exit path.
#
# WHY A SEAM. Validators are existing binaries that print `[PASS|FAIL]` rows and
# a final `VERDICT: PASS|FAIL` and exit 0 iff all pass. The `Validator` trait is
# the frontend-terminated fork whose conformers run them: a CLI binds a
# fork-exec conformer (parsing `VERDICT:` and the exit code with
# `parse_verdict`) and a health-check conformer; hermetic tests bind
# `ScriptedValidator` / `ScriptedDagValidator`. The loops are generic over
# `V: Validator` and `R: Reporter`, so every frontend reuses the same logic.
#
# Progress is reported through `Reporter.info`, so this adds no Reporter method.
#
# ENCAPSULATION: value-typed surface throughout, and no FFI. The back-off is
# the stdlib `std.time.sleep`, skipped when `interval_ms` is 0 so hermetic tests
# run at no wall cost.
# =============================================================================

from std.memory import ArcPointer
from std.time import sleep

from kci_iac import (
    ResourceGraph,
    Creds,
    ResourceStatus,
    RES_ABSENT,
    RES_PRESENT_MATCHED,
    RES_PRESENT_DRIFTED,
    RES_CONVERGING,
    RES_FAILED,
    dag_topo_order,
)

from kci_deploy.reporter import Reporter

from kci_logs import (
    DEFAULT_MAX_MESSAGE_BYTES,
    DEFAULT_MAX_RENDERED_RECORDS,
    RunLogTail,
    redact_secretish,
    render_run_log_tail,
)


comptime VALIDATION_PASS: Int = 0
"""The validator emitted `VERDICT: PASS` and exited 0."""
comptime VALIDATION_FAIL: Int = 1
"""The validator failed, or its verdict and exit code disagree."""
comptime VALIDATION_INDETERMINATE: Int = 2
"""No verdict could be read (no `VERDICT:` line). Not a pass; the gate keeps
polling."""


def verdict_label(code: Int) -> StaticString:
    """The VALIDATION_* code as PASS / FAIL / INDETERMINATE."""
    if code == VALIDATION_PASS:
        return "PASS"
    if code == VALIDATION_FAIL:
        return "FAIL"
    return "INDETERMINATE"


struct ValidationOutcome(Copyable, Movable, Deinitable):
    """The result of a single `Validator.run_once`:
      * `verdict`   -- one of the VALIDATION_* codes.
      * `exit_code` -- the validator process exit code (fork-exec conformer) or the
                       HTTP status (health conformer); -1 when not applicable.
      * `summary`   -- a one-line, human-readable result (the `VERDICT:` line, the
                       health status, or a "no verdict" note). Never carries a
                       secret.
      * `detail`    -- the validator's OWN output (its per-row lines), already
                       bounded and redacted by `render_validator_output_tail`; or,
                       for a conformer that does not hold that output, a block
                       naming where it is (`render_validator_output_elsewhere`).
                       Empty when the run passed or the conformer has neither.
      * `repeat_key`-- the cause with every per-attempt token removed: what the DAG
                       compares to decide whether a further attempt could say
                       anything new. Empty (the default) means "compare the
                       summary".
      * `no_retry_reason`
                    -- the producer's own statement that a further attempt cannot
                       differ, and why. Empty states nothing and retries as usual;
                       non-empty makes this verdict the step's answer on the attempt
                       that produced it. One-directional: there is no value meaning
                       "retryable", so a conformer that recognises nothing stays
                       silent rather than guessing.

    WHY `detail` EXISTS. Without it a failing step reports only
    `step 'x' FAIL (VERDICT: FAIL)`: the validator printed a row per assertion
    saying which one failed and why, and all of it was dropped at the conformer. A
    printer can only print what crosses the seam, so the evidence has to be on the
    value. `summary` stays one line, embeddable mid-sentence; `detail` is the
    bounded block underneath it.

    It is bounded and redacted at the point of capture, never at the point of
    print: a conformer that fills it by hand must pass its output through
    `render_validator_output_tail`. A conformer that does not hold the output must
    not synthesise rows into it; it uses `render_validator_output_elsewhere`, whose
    block is labelled as tool prose, because attributing the tool's words to the
    validator destroys the provenance that makes the row block worth printing."""

    var verdict: Int
    var exit_code: Int
    var summary: String
    var detail: String
    var repeat_key: String
    var no_retry_reason: String

    def __init__(
        out self,
        verdict: Int,
        exit_code: Int,
        var summary: String,
        var detail: String = String(""),
        var repeat_key: String = String(""),
        var no_retry_reason: String = String(""),
    ):
        self.verdict = verdict
        self.exit_code = exit_code
        self.summary = summary^
        self.detail = detail^
        self.repeat_key = repeat_key^
        self.no_retry_reason = no_retry_reason^

    def is_pass(self) -> Bool:
        """True iff the verdict is VALIDATION_PASS."""
        return self.verdict == VALIDATION_PASS

    def has_detail(self) -> Bool:
        """True iff `detail` carries a block."""
        return self.detail.byte_length() > 0

    def repeat_key_or_summary(self) -> String:
        """The value the repeat detector compares: the stated `repeat_key`, or the
        `summary` when none is stated, so a conformer that says nothing gets the plain
        summary comparison."""
        return (
            self.repeat_key.copy()
            if self.repeat_key.byte_length() > 0
            else self.summary.copy()
        )

    def states_no_retry(self) -> Bool:
        """True iff the producer states that a further attempt cannot differ
        (`no_retry_reason` is non-empty). There is deliberately no tri-state: the only
        way to reach True is for a producer to have written a sentence."""
        return self.no_retry_reason.byte_length() > 0

    @staticmethod
    def passed(
        exit_code: Int, summary: String, detail: String = String("")
    ) -> ValidationOutcome:
        """A PASS outcome."""
        return ValidationOutcome(
            VALIDATION_PASS, exit_code, summary, detail.copy()
        )

    @staticmethod
    def failed(
        exit_code: Int,
        summary: String,
        detail: String = String(""),
        repeat_key: String = String(""),
        no_retry_reason: String = String(""),
    ) -> ValidationOutcome:
        """A FAIL outcome."""
        return ValidationOutcome(
            VALIDATION_FAIL,
            exit_code,
            summary,
            detail.copy(),
            repeat_key.copy(),
            no_retry_reason.copy(),
        )

    @staticmethod
    def indeterminate(
        exit_code: Int,
        summary: String,
        detail: String = String(""),
        repeat_key: String = String(""),
        no_retry_reason: String = String(""),
    ) -> ValidationOutcome:
        """An INDETERMINATE outcome (no readable verdict)."""
        return ValidationOutcome(
            VALIDATION_INDETERMINATE,
            exit_code,
            summary,
            detail.copy(),
            repeat_key.copy(),
            no_retry_reason.copy(),
        )


comptime DEFAULT_MAX_OUTPUT_LINES: Int = 40
"""How many of a validator's LAST output lines a failure report carries. The
verdict and the failing rows are at the end of a validator's output."""

comptime DEFAULT_MAX_OUTPUT_LINE_BYTES: Int = 400
"""The byte cap on one rendered output line."""


def _clip_output_line(line: String, max_bytes: Int) -> String:
    """Clip `line` to at most `max_bytes` bytes on a UTF-8 boundary, stating how
    many bytes were dropped."""
    var b = line.as_bytes()
    if max_bytes <= 0 or len(b) <= max_bytes:
        return line.copy()
    var cut = max_bytes
    while cut > 0 and (Int(b[cut]) & 0xC0) == 0x80:
        cut -= 1
    var head = String(StringSlice(unsafe_from_utf8=b[0:cut]))
    return (
        head
        + String(" … [line clipped: ")
        + String(len(b) - cut)
        + String(" more byte(s)]")
    )


def _has_non_space(s: String) -> Bool:
    """True iff `s` holds a byte other than space, tab, CR or LF."""
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c != UInt8(0x20)
            and c != UInt8(0x09)
            and c != UInt8(0x0D)
            and c != UInt8(0x0A)
        ):
            return True
    return False


def _split_lines(s: String) -> List[String]:
    """Split `s` on LF; a trailing unterminated line is kept."""
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(0x0A):
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
    if start < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[start : len(b)])))
    return out^


def render_validator_output_tail(
    output: String,
    max_lines: Int = DEFAULT_MAX_OUTPUT_LINES,
    max_line_bytes: Int = DEFAULT_MAX_OUTPUT_LINE_BYTES,
) -> String:
    """The BOUNDED, REDACTED view of a validator's own stdout: the producer of
    `ValidationOutcome.detail`.

    Keeps the LAST `max_lines` lines (stating how many earlier ones were omitted),
    clips each to `max_line_bytes`, and passes every line through
    `redact_secretish`. Output that is entirely blank renders as an explicit "no
    output" statement, because an empty stream is an answer, not a missing report.
    Empty input renders as ""."""
    if output.byte_length() == 0:
        return String("")
    var lines = _split_lines(output)
    var non_blank = 0
    for i in range(len(lines)):
        if _has_non_space(lines[i]):
            non_blank += 1
    if non_blank == 0:
        return String(
            "  validator output: the validator produced NO OUTPUT on stdout —"
            " it may have died before its first flush, or it writes its rows to"
            " stderr. This is an ANSWER, not a missing report."
        )
    var n = len(lines)
    var cap = max_lines if max_lines > 0 else n
    var first = n - cap if n > cap else 0
    var out = (
        String("  validator output — showing ")
        + String(n - first)
        + String(" line(s)")
    )
    if first > 0:
        out += (
            String(", the LAST of ")
            + String(n)
            + String("; ")
            + String(first)
            + String(" EARLIER line(s) omitted")
        )
    out += String(":")
    for i in range(first, n):
        out += String("\n    ") + _clip_output_line(
            redact_secretish(lines[i]), max_line_bytes
        )
    return out^


def render_validator_output_elsewhere(
    where: String,
    commands: List[String],
    max_line_bytes: Int = DEFAULT_MAX_OUTPUT_LINE_BYTES,
) -> String:
    """The other producer of `ValidationOutcome.detail`, for a conformer that
    does NOT hold the validator's output at all (an in-cloud job whose transport
    reads terminal task counts while the rows went to the cloud's log service). It
    names WHERE the output is and the commands that read it, labelled as tool prose
    rather than validator rows. Empty `where` renders ""."""
    if where.byte_length() == 0:
        return String("")
    var out = String(
        "  validator output: NOT CAPTURED BY THIS SEAM — the deploy tool never"
        " held this validator's own rows. That is an ANSWER, not a missing"
        " report: the output exists, at"
    )
    out += String("\n    ") + _clip_output_line(
        redact_secretish(where), max_line_bytes
    )
    var rendered = 0
    for i in range(len(commands)):
        if commands[i].byte_length() == 0:
            continue
        if rendered == 0:
            out += String("\n  and is read with:")
        out += String("\n    ") + _clip_output_line(
            redact_secretish(commands[i]), max_line_bytes
        )
        rendered += 1
    return out^


def render_validator_output_read_by_the_tool(
    where: String,
    max_line_bytes: Int = DEFAULT_MAX_OUTPUT_LINE_BYTES,
) -> String:
    """The sibling of `render_validator_output_elsewhere` for the case where the
    tool DOES read the step's stream itself and prints what it got in the run-log
    block beside this one, so the operator is not sent to run a raw cloud command.
    It states that the rows are not carried in this block (this block is what a
    validation record keeps). Empty `where` renders ""."""
    if where.byte_length() == 0:
        return String("")
    return (
        String(
            "  validator output: READ BY THIS TOOL — kci reads this"
            " step's own stream itself and STATES WHAT IT GOT in the run-log"
            " block beside this one; no raw cloud command is needed. ⚠ THE"
            " ROWS ARE NOT CARRIED IN THIS BLOCK, and this block is what"
            " becomes DURABLE in the validation record — the record holds this"
            " pointer and the verdict, not the rows. The stream is"
        )
        + String("\n    ")
        + _clip_output_line(redact_secretish(where), max_line_bytes)
    )


def parse_verdict(stdout: String, exit_code: Int) -> ValidationOutcome:
    """Read a validator's verdict from its stdout and exit code:
      * `VERDICT: PASS` and exit 0      -> PASS (no detail).
      * `VERDICT: PASS` and exit != 0   -> FAIL: the two disagree.
      * `VERDICT: UNREADABLE`           -> FAIL: the validator was refused, not
                                           answered, so the run is evidence about
                                           the caller's authority, not the subject.
      * `VERDICT: FAIL`                 -> FAIL.
      * no VERDICT line                 -> INDETERMINATE.
    Every non-pass outcome carries the bounded output tail as `detail`."""
    var has_pass = stdout.find(String("VERDICT: PASS")) >= 0
    var has_unreadable = stdout.find(String("VERDICT: UNREADABLE")) >= 0
    var has_fail = stdout.find(String("VERDICT: FAIL")) >= 0
    if has_pass and exit_code == 0:
        return ValidationOutcome.passed(exit_code, String("VERDICT: PASS"))
    var rows = render_validator_output_tail(stdout)
    if has_pass and exit_code != 0:
        return ValidationOutcome.failed(
            exit_code,
            String("VERDICT: PASS but process exit ") + String(exit_code),
            rows,
        )
    if has_unreadable:
        return ValidationOutcome.failed(
            exit_code,
            String(
                "VERDICT: UNREADABLE — the validator could not OBSERVE its"
                " subject (it was refused, not answered), so this run is"
                " evidence about the caller's authority and NOT about the"
                " thing being validated. Read the VERDICT-REASON lines: they"
                " name the blinded rows and the permissions the job lacked."
                " process exit "
            )
            + String(exit_code),
            rows,
        )
    if has_fail:
        return ValidationOutcome.failed(exit_code, String("VERDICT: FAIL"), rows)
    return ValidationOutcome.indeterminate(
        exit_code,
        String("no VERDICT line (process exit ") + String(exit_code) + String(")"),
        rows,
    )


@fieldwise_init
struct PollBudget(Copyable, Movable, Deinitable):
    """The bounded poll window: at most `max_attempts` attempts, sleeping
    `interval_ms` between them."""

    var max_attempts: Int
    var interval_ms: Int

    @staticmethod
    def of(max_attempts: Int, interval_ms: Int) -> PollBudget:
        """A budget with `max_attempts` clamped to at least 1 and `interval_ms` to at
        least 0."""
        return PollBudget(
            max_attempts if max_attempts > 0 else 1,
            interval_ms if interval_ms >= 0 else 0,
        )

    def sleep_between(self):
        """Sleep `interval_ms` (no-op at 0, the hermetic setting)."""
        if self.interval_ms > 0:
            sleep(Float64(self.interval_ms) / 1000.0)


@fieldwise_init
struct ConvergeOutcome(Copyable, Movable, Deinitable):
    """The result of `poll_until_converged`:
      * `converged`      -- every node settled.
      * `failed`         -- some node reported FAILED.
      * `failed_node`    -- the first independently failed node, or "".
      * `attempts`       -- polling rounds used.
      * `drifted_node`   -- the first required node still PRESENT but DRIFTED at
                            timeout, or "".
      * `failed_nodes`   -- every independently failed node (a ROOT fault).
      * `blocked_nodes`  -- failed nodes behind a failed dependency, rendered
                            `<node> <- <failed ancestor>` (a consequence).
      * `nodes_scanned`  -- how many nodes the deciding round read.
      * `drifted_nodes` / `drifted_images` -- every required node still DRIFTED at
                            timeout, with the image each was serving.
    Neither `converged` nor `failed` means a timeout."""

    var converged: Bool
    var failed: Bool
    var failed_node: String
    var attempts: Int
    var drifted_node: String
    var failed_nodes: List[String]
    var blocked_nodes: List[String]
    var nodes_scanned: Int
    var drifted_nodes: List[String]
    var drifted_images: List[String]

    def drift_report(self) -> String:
        """Every drifted node and the image it was serving, as one line."""
        var out = String("")
        for i in range(len(self.drifted_nodes)):
            if i > 0:
                out += String("; ")
            var img = (
                self.drifted_images[i].copy()
                if i < len(self.drifted_images)
                else String("")
            )
            out += (
                String("'")
                + self.drifted_nodes[i]
                + String("' serving ")
                + (img if img.byte_length() > 0 else String("<no image read>"))
            )
        return out^

    def is_timeout(self) -> Bool:
        """True iff the budget ran out with no node FAILED and the graph unsettled."""
        return (not self.converged) and (not self.failed)

    def scan_was_complete(self, num_nodes: Int) -> Bool:
        """True iff the deciding round read every node. When False, a failure list
        is a LOWER bound."""
        return self.nodes_scanned >= num_nodes

    def failure_summary(self) -> String:
        """Root-fault, blocked and scanned counts, as one line."""
        return (
            String(len(self.failed_nodes))
            + String(" independently-failed node(s), ")
            + String(len(self.blocked_nodes))
            + String(" blocked by a failed dependency, ")
            + String(self.nodes_scanned)
            + String(" node(s) scanned")
        )

    @staticmethod
    def settled(attempts: Int, scanned: Int) -> ConvergeOutcome:
        """The graph settled."""
        return ConvergeOutcome(
            True,
            False,
            String(""),
            attempts,
            String(""),
            List[String](),
            List[String](),
            scanned,
            List[String](),
            List[String](),
        )

    @staticmethod
    def faulted(
        var roots: List[String],
        var blocked: List[String],
        attempts: Int,
        scanned: Int,
    ) -> ConvergeOutcome:
        """Some node FAILED: `roots` are independent faults, `blocked` consequences."""
        var head = roots[0].copy() if len(roots) > 0 else String("")
        return ConvergeOutcome(
            False,
            True,
            head^,
            attempts,
            String(""),
            roots^,
            blocked^,
            scanned,
            List[String](),
            List[String](),
        )

    @staticmethod
    def timed_out(
        attempts: Int,
        var drifted: List[String],
        var drifted_images: List[String],
        scanned: Int,
    ) -> ConvergeOutcome:
        """The budget ran out; `drifted` names required nodes still drifted."""
        var head = drifted[0].copy() if len(drifted) > 0 else String("")
        return ConvergeOutcome(
            False,
            False,
            String(""),
            attempts,
            head^,
            List[String](),
            List[String](),
            scanned,
            drifted^,
            drifted_images^,
        )


trait Validator(Movable, Deinitable):
    """One validation run: a fork-exec validator, a health probe, or a hermetic
    double. The gate loops call `run_once` until it passes or the budget ends."""

    def run_once(mut self) raises -> ValidationOutcome:
        """Run the validation once and return its outcome."""
        ...


def _id_in(needle: String, haystack: List[String]) -> Bool:
    """True iff `needle` is in `haystack`."""
    for ref h in haystack:
        if h == needle:
            return True
    return False


def _failed_ancestor(
    i: Int, deps_idx: List[List[Int]], is_failed: List[Bool]
) -> Int:
    """The index of a FAILED node reachable through `i`'s dependencies, or -1. A
    node with one is a consequence of that fault, not an independent one."""
    var n = len(deps_idx)
    var visited = List[Bool]()
    for _k in range(n):
        visited.append(False)
    var stack = List[Int]()
    for k in range(len(deps_idx[i])):
        stack.append(deps_idx[i][k])
    while len(stack) > 0:
        var cur = stack[len(stack) - 1]
        _ = stack.pop()
        if cur < 0 or cur >= n or visited[cur]:
            continue
        visited[cur] = True
        if is_failed[cur]:
            return cur
        for k in range(len(deps_idx[cur])):
            stack.append(deps_idx[cur][k])
    return -1


def poll_until_converged[
    R: Reporter
](
    mut graph: ResourceGraph,
    creds: Creds,
    budget: PollBudget,
    mut reporter: R,
    require_present_ids: List[String] = List[String](),
) raises -> ConvergeOutcome:
    """Poll every node's live `read_status` until the graph settles, a node
    fails, or the budget is exhausted.

    Each round reads EVERY node, so a failure report names all independently failed
    nodes (roots) and separates failures behind a failed dependency (blocked),
    rather than stopping at the first. A node still RES_CONVERGING keeps the loop
    going. Nodes named in `require_present_ids` must also be PRESENT and MATCHED:
    ABSENT or DRIFTED counts as still converging, and a DRIFTED served node is
    reported with the image it is serving instead of the applied one. Raises only
    on a backend read fault."""
    var n = graph.num_nodes()
    reporter.info(
        String("converge: begin — ")
        + String(n)
        + String(" node(s), up to ")
        + String(budget.max_attempts)
        + String(" attempt(s)")
    )
    var node_ids = List[String]()
    var dep_names = List[List[String]]()
    for i in range(n):
        node_ids.append(graph.node(i).logical_id())
        dep_names.append(graph.node(i).depends_on())
    var deps_idx = List[List[Int]]()
    for i in range(n):
        var di = List[Int]()
        for k in range(len(dep_names[i])):
            for j in range(n):
                if node_ids[j] == dep_names[i][k]:
                    di.append(j)
                    break
        deps_idx.append(di^)
    var attempt = 0
    var drifted_node = String("")
    var drifted_all = List[String]()
    var drifted_imgs = List[String]()
    while attempt < budget.max_attempts:
        attempt += 1
        var any_converging = False
        drifted_node = String("")
        drifted_all = List[String]()
        drifted_imgs = List[String]()
        var is_failed = List[Bool]()
        for _k in range(n):
            is_failed.append(False)
        var scanned = 0
        for i in range(n):
            var st = graph.node(i).read_status(creds)
            scanned += 1
            if st.phase == RES_FAILED:
                is_failed[i] = True
            if st.phase == RES_CONVERGING:
                any_converging = True
            elif st.phase == RES_ABSENT and len(require_present_ids) > 0:
                if _id_in(graph.node(i).logical_id(), require_present_ids):
                    any_converging = True
            elif st.phase == RES_PRESENT_DRIFTED and len(require_present_ids) > 0:
                var lid = graph.node(i).logical_id()
                if _id_in(lid, require_present_ids):
                    any_converging = True
                    drifted_all.append(lid.copy())
                    drifted_imgs.append(st.live_image.copy())
                    if drifted_node.byte_length() == 0:
                        drifted_node = lid^
        var roots = List[String]()
        var blocked = List[String]()
        for i in range(n):
            if not is_failed[i]:
                continue
            var anc = _failed_ancestor(i, deps_idx, is_failed)
            if anc >= 0:
                blocked.append(
                    node_ids[i] + String(" <- ") + node_ids[anc]
                )
            else:
                roots.append(node_ids[i].copy())
        if len(roots) > 0 or len(blocked) > 0:
            for ref r in roots:
                reporter.info(String("converge: FAILED node ") + r)
            for ref b in blocked:
                reporter.info(
                    String("converge: node '")
                    + b
                    + String("' also FAILED, but behind a failed dependency"
                             " (a consequence, not an independent fault)")
                )
            var out = ConvergeOutcome.faulted(
                roots^, blocked^, attempt, scanned
            )
            reporter.info(String("converge: FAILED — ") + out.failure_summary())
            if not out.scan_was_complete(n):
                reporter.info(
                    String("converge: ⚠ INCOMPLETE SCAN — only ")
                    + String(scanned)
                    + String(" of ")
                    + String(n)
                    + String(" node(s) were read, so this list is a LOWER BOUND;")
                    + String(" other nodes may also be broken and were never")
                    + String(" asked")
                )
            return out^
        if not any_converging:
            reporter.info(
                String("converge: settled on attempt ") + String(attempt)
            )
            return ConvergeOutcome.settled(attempt, scanned)
        reporter.info(
            String("converge: attempt ")
            + String(attempt)
            + String("/")
            + String(budget.max_attempts)
            + String(" — a node is still converging")
            + (
                String(" (served node '")
                + drifted_node
                + String("' is PRESENT but DRIFTED — not serving the applied"
                        " image)")
                if drifted_node.byte_length() > 0
                else String("")
            )
        )
        if attempt < budget.max_attempts:
            budget.sleep_between()
    if drifted_node.byte_length() > 0:
        reporter.info(
            String("converge: timeout after ")
            + String(budget.max_attempts)
            + String(" attempt(s) — ")
            + String(len(drifted_all))
            + String(" served node(s) PRESENT but DRIFTED, never serving the")
            + String(" image this deploy applied: ")
            + ConvergeOutcome.timed_out(
                attempt, drifted_all.copy(), drifted_imgs.copy(), n
            ).drift_report()
        )
        return ConvergeOutcome.timed_out(attempt, drifted_all^, drifted_imgs^, n)
    reporter.info(
        String("converge: timeout after ")
        + String(budget.max_attempts)
        + String(" attempt(s) — a node never settled")
    )
    return ConvergeOutcome.timed_out(
        attempt, List[String](), List[String](), n
    )


def run_validation_gate[
    V: Validator, R: Reporter
](
    mut validator: V,
    budget: PollBudget,
    mut reporter: R,
) raises -> ValidationOutcome:
    """Run `validator` until it passes or `budget` is exhausted, reporting each
    attempt. Returns the PASS outcome, or the LAST outcome on timeout."""
    reporter.info(
        String("validate: begin — up to ")
        + String(budget.max_attempts)
        + String(" attempt(s), interval ")
        + String(budget.interval_ms)
        + String("ms")
    )
    var last = ValidationOutcome.indeterminate(-1, String("no attempt ran"))
    var attempt = 0
    while attempt < budget.max_attempts:
        attempt += 1
        var out = validator.run_once()
        reporter.info(
            String("validate: attempt ")
            + String(attempt)
            + String("/")
            + String(budget.max_attempts)
            + String(" verdict=")
            + verdict_label(out.verdict)
            + String(" (")
            + out.summary
            + String(")")
        )
        if out.is_pass():
            reporter.info(
                String("validate: PASS on attempt ") + String(attempt)
            )
            return out^
        last = out.copy()
        if attempt < budget.max_attempts:
            budget.sleep_between()
    reporter.info(
        String("validate: FAIL after ")
        + String(budget.max_attempts)
        + String(" attempt(s) (timeout) — last verdict=")
        + verdict_label(last.verdict)
    )
    return last^


def run_all_validation_gates[
    V: Validator, R: Reporter
](
    mut validators: List[V],
    labels: List[String],
    budget: PollBudget,
    mut reporter: R,
) raises -> ValidationOutcome:
    """Run each validator's gate in order (serially), stopping at the first that
    does not pass; `labels[i]` names gate `i` in reports. Zero gates is a pass."""
    var total = len(validators)
    reporter.info(
        String("validate-all: ") + String(total) + String(" gate(s) to run")
    )
    if total == 0:
        return ValidationOutcome.passed(0, String("0 validation gate(s)"))
    for i in range(total):
        var label = labels[i].copy() if i < len(labels) else (
            String("step ") + String(i)
        )
        reporter.info(
            String("validate-all: gate ")
            + String(i + 1)
            + String("/")
            + String(total)
            + String(" '")
            + label
            + String("' — begin")
        )
        var out = run_validation_gate[V, R](validators[i], budget, reporter)
        if not out.is_pass():
            reporter.info(
                String("validate-all: gate '")
                + label
                + String("' FAILED (")
                + out.summary
                + String(") — the wave does not advance")
            )
            return ValidationOutcome.failed(
                out.exit_code,
                String("gate '") + label + String("' failed: ") + out.summary,
            )
        reporter.info(
            String("validate-all: gate '") + label + String("' PASSED")
        )
    return ValidationOutcome.passed(
        0, String("all ") + String(total) + String(" validation gate(s) passed")
    )


comptime STEP_PASS: Int = 0
"""The step passed."""
comptime STEP_FAIL: Int = 1
"""The step failed (a FAIL verdict, a timeout, or a start that never succeeded)."""
comptime STEP_SKIPPED: Int = 2
"""The step never ran because a dependency did not pass."""


def step_status_label(status: Int) -> StaticString:
    """The STEP_* code as PASS / FAIL / SKIPPED."""
    if status == STEP_PASS:
        return "PASS"
    if status == STEP_SKIPPED:
        return "SKIPPED"
    return "FAIL"


comptime TEARDOWN_PATH_SCHEDULER_FAULT: StaticString = "SCHEDULER-FAULT"
"""Teardown path token: the scheduler raised, so every step was torn down as
collateral, including any execution still in flight."""

comptime TEARDOWN_PATH_WAVE_COMPLETED: StaticString = "WAVE-COMPLETED"
"""Teardown path token: the scheduler decided every step and returned; the
release is the ordinary end of the step's lifecycle."""


def step_teardown_reason(
    scheduler_fault: String, status: Int, summary: String
) -> String:
    """WHY a step's teardown fired, as one line starting with its path token.

    A non-empty `scheduler_fault` means the scheduler raised: the step was torn down
    as collateral and never reached a verdict of its own, and the line quotes the
    fault. Otherwise the wave completed and the line carries the step's status and
    verdict summary.

    The two paths reach different media. On WAVE-COMPLETED the reason is stamped on
    `StepResult.teardown_reason`, so a validation record can carry it. On
    SCHEDULER-FAULT the fault is re-raised before any `DagOutcome` exists, so the
    reason reaches the log only."""
    if scheduler_fault.byte_length() > 0:
        return (
            String(TEARDOWN_PATH_SCHEDULER_FAULT)
            + String(
                " — the validate DAG's scheduler RAISED, so this step was torn"
                " down as COLLATERAL rather than because it finished: an"
                " execution still in flight under it is CANCELLED by this"
                " release, and this step never reached a verdict of its own."
                " Scheduler fault: "
            )
            + scheduler_fault.replace("\n", " / ")
        )
    return (
        String(TEARDOWN_PATH_WAVE_COMPLETED)
        + String(" — the scheduler decided every step and returned; this one is ")
        + String(step_status_label(status))
        + String(
            ", so the release is the ordinary end of its lifecycle. Step"
            " verdict: "
        )
        + (
            summary.replace("\n", " / ")
            if summary.byte_length() > 0
            else String("(none recorded)")
        )
    )


struct StepResult(Copyable, Movable, Deinitable):
    """One step's result in a `DagOutcome`: its name, STEP_* status, the
    deciding `ValidationOutcome`, and the reason its teardown fired (stamped by
    `run_validation_dag`)."""

    var name: String
    var status: Int
    var outcome: ValidationOutcome
    var teardown_reason: String

    def __init__(out self, var name: String, status: Int, var outcome: ValidationOutcome):
        self.name = name^
        self.status = status
        self.outcome = outcome^
        self.teardown_reason = String("")

    def __init__(
        out self,
        var name: String,
        status: Int,
        var outcome: ValidationOutcome,
        var teardown_reason: String,
    ):
        self.name = name^
        self.status = status
        self.outcome = outcome^
        self.teardown_reason = teardown_reason^

    def is_pass(self) -> Bool:
        return self.status == STEP_PASS

    def is_skipped(self) -> Bool:
        return self.status == STEP_SKIPPED


struct DagOutcome(Copyable, Movable, Deinitable):
    """The result of a validation DAG: `passed` iff every step passed, and one
    `StepResult` per step in declaration order."""

    var passed: Bool
    var results: List[StepResult]

    def __init__(out self, passed: Bool, var results: List[StepResult]):
        self.passed = passed
        self.results = results^

    def pass_count(self) -> Int:
        var c = 0
        for ref r in self.results:
            if r.status == STEP_PASS:
                c += 1
        return c

    def fail_count(self) -> Int:
        var c = 0
        for ref r in self.results:
            if r.status == STEP_FAIL:
                c += 1
        return c

    def skipped_count(self) -> Int:
        var c = 0
        for ref r in self.results:
            if r.status == STEP_SKIPPED:
                c += 1
        return c

    def summary(self) -> String:
        """Pass / fail / skipped counts as one line."""
        return (
            String(self.pass_count())
            + String("/")
            + String(len(self.results))
            + String(" step(s) passed (")
            + String(self.fail_count())
            + String(" failed, ")
            + String(self.skipped_count())
            + String(" skipped)")
        )


trait DagValidator(Validator):
    """A `Validator` (so `run_once` still drives it serially) that also supports
    the START / POLL split the parallel DAG scheduler drives:
      * `start`   -- launch the work (idempotent). A blocking validator does
                     nothing here and runs the whole attempt in `poll`.
      * `poll`    -- one non-blocking check: `None` while running, `Some(outcome)`
                     once terminal. A blocking validator returns `Some(run_once())`;
                     an asynchronous one (a cloud job) returns `None` until its
                     execution reaches a terminal state.
      * `restart` -- discard the finished attempt so the next `start()` launches a
                     fresh one; returns whether it re-armed.
    The remaining methods have defaults, so a conformer overrides only what it
    can say."""

    def start(mut self) raises:
        """Launch the validation work (idempotent)."""
        ...

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        """One non-blocking check for a terminal verdict (None = still running)."""
        ...

    def restart(mut self) raises -> Bool:
        """Discard the FINISHED attempt so the next `start()` launches a fresh one.
        Returns True iff this validator re-armed: running it again is safe AND will
        produce a genuinely new observation.

        This is a safety seam, not bookkeeping. `run_validation_dag` retries a
        non-pass verdict only while this says True, because whether a gate may be
        retried is a property of what the gate DOES:
          * a health probe or a fork-exec run -> True: a re-run is a fresh request or a
            fresh process, which is what absorbs a transient refusal while a
            just-written grant propagates;
          * a validator job the gate itself defines and runs -> True;
          * a gate that runs a job the BUNDLE declared (one with an external side
            effect, such as sending a message) -> False: a second start would repeat
            the side effect. Such a step keeps its first terminal verdict.
        A conformer that cannot cheaply tell must return False: the cost of False is a
        slower diagnosis; the cost of a wrong True is a duplicated side effect."""
        ...

    def teardown(mut self) raises:
        """Release any cloud resource this validator created for its step. Called by
        `run_validation_dag` for EVERY validator in the wave, on EVERY exit path,
        after the wave has been decided.

        Every validator, not only the ones that started: the scheduler keeps no
        started-set for this pass (that bookkeeping is what a raise destroys), so a
        skipped step's validator is called too and must answer by doing nothing.
        Whether anything was minted is the conformer's fact.

        Defaults to a no-op: a health probe and a fork-exec run create nothing that
        outlives them, and a gate running a job the bundle declared must not delete it
        (the bundle owns it). Conformers that mint a cloud object of their own
        override it, because a resource reaped only as a side effect of observing a
        terminal state leaks on every exit path without such an observation: a
        per-step timeout, a raise escaping the scheduler, a killed process.

        Contract for an override:
          * idempotent -- an already-released resource makes it a no-op;
          * best-effort -- never raise for a release that did not take; the verdict is
            decided and a residual leak is a cleanup finding, not a gate result;
          * release only what THIS validator created; when in doubt, decline."""
        pass

    def last_observed_state(self) -> String:
        """The last NON-terminal state this validator observed, as one human clause,
        or empty when the conformer has nothing to add (the default).

        `poll()` collapses every live state into `None`, which is correct for
        scheduling. But a step that times out then gets one sentence, "did not reach a
        terminal verdict", which is true of two faults with different next actions:
        (a) the DAG stopped polling while the execution was still running (the budget
        was too small for this workload), and (b) the execution finished and its
        verdict was never observed. This changes no verdict and no budget; it only
        improves the report.

        Contract for an override: name the handle an operator can read (the execution,
        the process); name which live state was last seen (PENDING and
        NOT-YET-OBSERVABLE must read differently from RUNNING); say how to read it.
        One clause, no trailing period: the DAG appends it after a dash."""
        return String("")

    def declared_wall_s(self) -> Int:
        """The wall, in seconds, this step's own declaration entitles it to run for,
        or 0 when the conformer declares nothing (the default: the DAG uses the CLI
        budget as given).

        A step that declares a long task timeout must not be judged by a poll budget
        far shorter than that timeout: the job keeps running and reports its rows to
        nobody. `derived_step_poll_attempts` raises the step's poll ceiling to cover
        this value."""
        return 0

    def failure_run_log_tail(mut self) raises -> Optional[RunLogTail]:
        """The failing step's own stage-log stream, fetched, or `None` when this
        conformer has no run to read (the default).

        The deploy tool knows which run failed and where its stage records are, so it
        fetches them instead of handing the operator a URL. `run_validation_dag`
        renders the result with `render_run_log_tail`, which distinguishes `None`
        (nothing printed), a tail with records (the last N, bounded), a tail with no
        records ("NO STAGE RECORDS", stated, because an empty stream is an answer), and
        a tail carrying a fault (one line naming it).

        Contract: this may NOT change a verdict. It runs only after a step was decided
        STEP_FAIL, and the DAG catches anything it raises. It may not print a secret:
        return records that came through the log reader's field allow-list, never a
        tail hand-built from a raw response body."""
        return None


def derived_step_poll_attempts(
    cli_attempts: Int, interval_ms: Int, declared_wall_s: Int
) -> Int:
    """How many poll rounds `run_validation_dag` gives ONE step: the operator's
    attempt count, RAISED to cover a wall the step itself declared
    (`declared_wall_s`), rounding up so the enforced wall is never shorter than the
    declared one. Returns `cli_attempts` when the step declares nothing or the
    interval is 0. Never lowers the operator's budget.

    Derived rather than tuned: a fixed poll budget and a step's declared timeout
    are maintained against different measurements and drift apart; deriving one
    from the other removes the second number.

    This bounds how long ONE attempt is watched. The identical-outcome stop below
    bounds how many times an UNCHANGED answer is re-launched; the two do not
    conflict."""
    if declared_wall_s <= 0 or interval_ms <= 0:
        return cli_attempts
    var need = (declared_wall_s * 1000 + interval_ms - 1) // interval_ms
    return need if need > cli_attempts else cli_attempts


comptime IDENTICAL_OUTCOME_LIMIT: Int = 5
"""Floor (1) of the deterministic-failure stop: how many consecutive
byte-identical non-PASS repeat keys the stop requires. Necessary, not
sufficient: the streak must also span `IDENTICAL_OUTCOME_MIN_WALL_S`."""

comptime IDENTICAL_OUTCOME_MIN_WALL_S: Int = 90
"""Floor (2): how many seconds an identical streak must span before the stop
may fire, sized to the upper end of a typical IAM-propagation window.

Both floors are a floor on evidence, not a ceiling on attempts: the stop can
only end a step that is already failing EARLIER, it never turns a red into a
green, and it never fires while anything about the answer is changing. A step
that fails fast on a precondition that takes longer than this to settle is
still stopped early; a conformer that knows its failure is final states it with
`no_retry_reason` instead."""


def derived_identical_outcome_rounds(interval_ms: Int) -> Int:
    """Floor (2) in ROUNDS at this poll interval, rounded up (a floor division
    would make the enforced wall shorter than the stated one). `interval_ms <= 0`
    -> 0: a round that costs no wall measures no wall, so in hermetic runs the stop
    is exactly `IDENTICAL_OUTCOME_LIMIT`."""
    if interval_ms <= 0:
        return 0
    return (IDENTICAL_OUTCOME_MIN_WALL_S * 1000 + interval_ms - 1) // interval_ms


def identical_outcome_stop_is_due(
    streak: Int, streak_rounds: Int, interval_ms: Int
) -> Bool:
    """The whole stop decision, both floors ANDed:
      * `streak`        -- consecutive attempts whose repeat key was identical;
      * `streak_rounds` -- poll rounds the streak has spanned;
      * `interval_ms`   -- converts rounds into seconds (0 makes the time floor
                           vacuous).
    ANDed, never ORed: the count alone stops a fast probe inside the propagation
    window it exists to wait out, and the wall alone stops a slow step after a
    single repeated answer."""
    if streak < IDENTICAL_OUTCOME_LIMIT:
        return False
    return streak_rounds >= derived_identical_outcome_rounds(interval_ms)


def _step_name_index(names: List[String], needle: String, n: Int) -> Int:
    """The index of step `needle` among the first `n` names, or -1."""
    for i in range(n):
        if names[i] == needle:
            return i
    return -1


def _report_failure_output[
    R: Reporter
](outcome: ValidationOutcome, step_name: String, mut reporter: R) raises:
    """Print a failed step's `detail` block (its validator's own output). Never
    raises: a report fault must not change the decided verdict."""
    if not outcome.has_detail():
        return
    try:
        reporter.info(
            String("validate-dag: step '")
            + step_name
            + String("' — its validator's own output:\n")
            + outcome.detail
        )
    except:
        pass


def _report_failure_run_logs[
    V: DagValidator, R: Reporter
](mut validators: List[V], i: Int, step_name: String, mut reporter: R) raises:
    """Fetch and print a failed step's run-log tail through the conformer's
    `failure_run_log_tail`. A fault in the fetch is reported as one line; nothing
    here raises or changes the decided verdict."""
    var tail_opt = Optional[RunLogTail](None)
    var seam_error = String("")
    try:
        tail_opt = validators[i].failure_run_log_tail()
    except e:
        seam_error = String(e)
    try:
        if seam_error.byte_length() > 0:
            reporter.info(
                String("validate-dag: step '")
                + step_name
                + String("' run-log enrichment FAILED to run: ")
                + seam_error
                + String(" — the step verdict above is unchanged")
            )
        elif tail_opt:
            reporter.info(
                String("validate-dag: step '")
                + step_name
                + String("' — its run's own stage log:\n")
                + render_run_log_tail(
                    tail_opt.value(),
                    DEFAULT_MAX_RENDERED_RECORDS,
                    DEFAULT_MAX_MESSAGE_BYTES,
                )
            )
    except:
        pass


def _run_validation_dag_steps[
    V: DagValidator, R: Reporter
](
    mut validators: List[V],
    names: List[String],
    deps: List[List[String]],
    budget: PollBudget,
    mut reporter: R,
    max_jobs: Int = 0,
) raises -> DagOutcome:
    """The scheduler: run the wave's steps as a DAG and decide every step.

    `names[i]` and `deps[i]` (names of steps `i` depends on) describe step `i`;
    a dangling or self dependency, a cycle, or mismatched lengths raise before
    anything starts. Each round:
      1. propagate SKIPPED to every step with a dependency that finished without
         passing;
      2. re-start steps whose previous attempt was re-armed for a retry;
      3. start ready steps (every dependency passed), up to `max_jobs` concurrent
         (0 = unbounded). A start that raises affects only that step, which retries
         within its own budget;
      4. poll every running step. A PASS is final. A non-pass is retried only when
         the validator re-arms (`restart()`), the step's own budget remains, the
         outcome does not state `no_retry_reason`, and the identical-outcome stop
         is not due; otherwise the step FAILS with a note saying which of those
         ended it;
      5. charge one round to every step that has started (or failed to start);
         a step that exhausts its own budget FAILS with a summary that says whether
         it never started, timed out after attempts, or never reached a terminal
         state (with `last_observed_state`).
    Budgets are per step: time spent blocked on a dependency is not charged."""
    var n = len(validators)
    if len(names) != n or len(deps) != n:
        raise Error(
            String("run_validation_dag: validators/names/deps length mismatch (")
            + String(n)
            + String(" / ")
            + String(len(names))
            + String(" / ")
            + String(len(deps))
            + String(")")
        )
    reporter.info(
        String("validate-dag: begin — ")
        + String(n)
        + String(" step(s), up to ")
        + String(budget.max_attempts)
        + String(" round(s), concurrency ")
        + (String("auto") if max_jobs <= 0 else String(max_jobs))
    )
    if n == 0:
        return DagOutcome(True, List[StepResult]())

    var deps_idx = List[List[Int]]()
    for i in range(n):
        var di = List[Int]()
        for k in range(len(deps[i])):
            var idx = _step_name_index(names, deps[i][k], n)
            if idx < 0:
                raise Error(
                    String("run_validation_dag: step '")
                    + names[i]
                    + String("' depends on '")
                    + deps[i][k]
                    + String("' which is not a step in the wave (dangling")
                    + String(" dependency)")
                )
            if idx == i:
                raise Error(
                    String("run_validation_dag: step '")
                    + names[i]
                    + String("' depends on itself (a self-cycle)")
                )
            di.append(idx)
        deps_idx.append(di^)
    # Raises on a dependency cycle before any step starts.
    _ = dag_topo_order(deps_idx)

    var started = List[Bool]()
    var done = List[Bool]()
    var status = List[Int]()
    var outcomes = List[ValidationOutcome]()
    for _i in range(n):
        started.append(False)
        done.append(False)
        status.append(-1)
        outcomes.append(
            ValidationOutcome.indeterminate(-1, String("not run"))
        )

    var step_rounds = List[Int]()
    var restart_pending = List[Bool]()
    var attempts = List[Int]()
    var identical_outcomes = List[Int]()
    var last_repeat_key = List[String]()
    var streak_start_round = List[Int]()
    var start_failures = List[Int]()
    var last_start_error = List[String]()
    var step_max_attempts = List[Int]()
    for i in range(n):
        step_rounds.append(0)
        restart_pending.append(False)
        attempts.append(0)
        identical_outcomes.append(0)
        last_repeat_key.append(String(""))
        streak_start_round.append(0)
        start_failures.append(0)
        last_start_error.append(String(""))
        var declared_s = validators[i].declared_wall_s()
        var cap = derived_step_poll_attempts(
            budget.max_attempts, budget.interval_ms, declared_s
        )
        if cap > budget.max_attempts:
            reporter.info(
                String("validate-dag: step '")
                + names[i]
                + String("' is entitled to a ")
                + String(declared_s)
                + String("s per-attempt deadline, so its poll ceiling is")
                + String(" DERIVED from that: ")
                + String(cap)
                + String(" round(s) x ")
                + String(budget.interval_ms)
                + String("ms, up from the ")
                + String(budget.max_attempts)
                + String(" round(s) (~")
                + String((budget.max_attempts * budget.interval_ms) // 1000)
                + String("s) this run asked for. A step cannot be entitled to")
                + String(" run for ")
                + String(declared_s)
                + String("s and be judged at ~")
                + String((budget.max_attempts * budget.interval_ms) // 1000)
                + String("s.")
            )
        step_max_attempts.append(cap)
    while True:
        # (1) Propagate SKIPPED through failed or skipped dependencies.
        var changed = True
        while changed:
            changed = False
            for i in range(n):
                if done[i]:
                    continue
                for k in range(len(deps_idx[i])):
                    var d = deps_idx[i][k]
                    if done[d] and status[d] != STEP_PASS:
                        status[i] = STEP_SKIPPED
                        done[i] = True
                        outcomes[i] = ValidationOutcome.failed(
                            -1,
                            String("skipped: dependency '")
                            + names[d]
                            + String("' ")
                            + step_status_label(status[d]),
                        )
                        reporter.info(
                            String("validate-dag: step '")
                            + names[i]
                            + String("' SKIPPED (dependency '")
                            + names[d]
                            + String("' ")
                            + step_status_label(status[d])
                            + String(")")
                        )
                        changed = True
                        break

        for i in range(n):
            # (2) Re-start steps re-armed for a retry.
            if restart_pending[i] and not done[i]:
                restart_pending[i] = False
                try:
                    validators[i].start()
                except e:
                    start_failures[i] += 1
                    last_start_error[i] = String(e)
                    restart_pending[i] = True
                    reporter.info(
                        String("validate-dag: step '")
                        + names[i]
                        + String("' could not RE-START (failure ")
                        + String(start_failures[i])
                        + String("): ")
                        + last_start_error[i]
                        + String(" — will retry within its own budget")
                    )
                    continue
                start_failures[i] = 0
                reporter.info(
                    String("validate-dag: step '")
                    + names[i]
                    + String("' retrying (attempt ")
                    + String(attempts[i] + 1)
                    + String(") — the previous attempt's verdict was not")
                    + String(" terminal for this gate")
                )

        # (3) Start ready steps, within the concurrency limit.
        var running = 0
        for i in range(n):
            if started[i] and not done[i]:
                running += 1
        var slots = (n if max_jobs <= 0 else max_jobs) - running
        for i in range(n):
            if slots <= 0:
                break
            if done[i] or started[i]:
                continue
            var ready = True
            for k in range(len(deps_idx[i])):
                var d = deps_idx[i][k]
                if (not done[d]) or status[d] != STEP_PASS:
                    ready = False
                    break
            if ready:
                try:
                    validators[i].start()
                except e:
                    start_failures[i] += 1
                    last_start_error[i] = String(e)
                    reporter.info(
                        String("validate-dag: step '")
                        + names[i]
                        + String("' could not START (failure ")
                        + String(start_failures[i])
                        + String("): ")
                        + last_start_error[i]
                        + String(" — the OTHER steps are unaffected; this one")
                        + String(" retries within its own budget")
                    )
                    continue
                start_failures[i] = 0
                started[i] = True
                slots -= 1
                reporter.info(
                    String("validate-dag: step '") + names[i] + String("' started")
                )

        for i in range(n):
            if started[i] and not done[i]:
                # (4) Poll a running step; decide pass, retry or fail.
                var terminal = validators[i].poll()
                if terminal:
                    var out = terminal.value().copy()
                    if out.is_pass():
                        status[i] = STEP_PASS
                        done[i] = True
                        reporter.info(
                            String("validate-dag: step '")
                            + names[i]
                            + String("' ")
                            + step_status_label(STEP_PASS)
                            + String(" (")
                            + out.summary
                            + String(")")
                        )
                        outcomes[i] = out^
                        continue
                    attempts[i] += 1
                    outcomes[i] = out.copy()
                    var repeat_key = out.repeat_key_or_summary()
                    if attempts[i] > 1 and repeat_key == last_repeat_key[i]:
                        identical_outcomes[i] += 1
                    else:
                        identical_outcomes[i] = 1
                        last_repeat_key[i] = repeat_key^
                        streak_start_round[i] = step_rounds[i]
                    var streak_rounds = step_rounds[i] - streak_start_round[i]
                    var deterministic = identical_outcome_stop_is_due(
                        identical_outcomes[i], streak_rounds, budget.interval_ms
                    )
                    var rearmed = validators[i].restart()
                    var budget_left = step_rounds[i] + 1 < step_max_attempts[i]
                    var states_no_retry = out.states_no_retry()
                    if (
                        rearmed
                        and budget_left
                        and not deterministic
                        and not states_no_retry
                    ):
                        restart_pending[i] = True
                        reporter.info(
                            String("validate-dag: step '")
                            + names[i]
                            + String("' attempt ")
                            + String(attempts[i])
                            + String(" did not pass (")
                            + out.summary
                            + String(") — retrying within its own budget")
                        )
                        continue
                    status[i] = STEP_FAIL
                    done[i] = True
                    var not_retried_note = String("")
                    if not rearmed:
                        not_retried_note = String(
                            " [not retried: this gate declares itself"
                            " NOT safely re-runnable]"
                        )
                    elif states_no_retry:
                        not_retried_note = (
                            String(" [not retried after ")
                            + String(attempts[i])
                            + String(" attempt(s): the step's own verdict")
                            + String(" states that no further attempt can")
                            + String(" differ — ")
                            + out.no_retry_reason
                            + String(". ")
                            + String(step_max_attempts[i] - step_rounds[i] - 1)
                            + String(" round(s) of this step's own budget were")
                            + String(" deliberately NOT spent]")
                        )
                    elif deterministic:
                        not_retried_note = (
                            String(" [not retried: the outcome was")
                            + String(" BYTE-IDENTICAL on ")
                            + String(identical_outcomes[i])
                            + String(" consecutive attempt(s) spanning ")
                            + String(
                                (streak_rounds * budget.interval_ms) // 1000
                            )
                            + String("s, at or past the ")
                            + String(
                                (
                                    derived_identical_outcome_rounds(
                                        budget.interval_ms
                                    )
                                    * budget.interval_ms
                                )
                                // 1000
                            )
                            + String("s settling floor]")
                        )
                    reporter.info(
                        String("validate-dag: step '")
                        + names[i]
                        + String("' ")
                        + step_status_label(STEP_FAIL)
                        + String(" (")
                        + out.summary
                        + String(")")
                        + not_retried_note
                    )
                    if rearmed and states_no_retry:
                        outcomes[i] = ValidationOutcome.failed(
                            out.exit_code,
                            out.summary
                            + String(" [NOT RETRIED after ")
                            + String(attempts[i])
                            + String(" attempt(s) — ")
                            + out.no_retry_reason
                            + String(". This is NOT budget exhaustion (")
                            + String(step_max_attempts[i] - step_rounds[i] - 1)
                            + String(
                                " round(s) unspent) and NOT a gate that refuses"
                                " to re-run: the verdict itself states that a"
                                " further attempt could only reproduce it.]"
                            ),
                            out.detail.copy(),
                        )
                    elif rearmed and deterministic:
                        outcomes[i] = ValidationOutcome.failed(
                            out.exit_code,
                            String("stopped retrying after ")
                            + String(attempts[i])
                            + String(" attempt(s): the outcome was")
                            + String(" BYTE-IDENTICAL on the last ")
                            + String(identical_outcomes[i])
                            + String(" of them, over ")
                            + String(
                                (streak_rounds * budget.interval_ms) // 1000
                            )
                            + String("s — past the ")
                            + String(
                                (
                                    derived_identical_outcome_rounds(
                                        budget.interval_ms
                                    )
                                    * budget.interval_ms
                                )
                                // 1000
                            )
                            + String("s settling floor, so this is not a world")
                            + String(" that is still converging. A further")
                            + String(" attempt could only")
                            + String(" reproduce it. This is NOT budget")
                            + String(" exhaustion — ")
                            + String(step_max_attempts[i] - step_rounds[i] - 1)
                            + String(" round(s) of this step's own budget were")
                            + String(" deliberately NOT spent — and NOT a gate")
                            + String(" that refuses to re-run. Verdict: ")
                            + out.summary,
                            out.detail.copy(),
                        )
                    else:
                        outcomes[i] = out^
                    _report_failure_output[R](outcomes[i], names[i], reporter)
                    _report_failure_run_logs[V, R](
                        validators, i, names[i], reporter
                    )

        var all_done = True
        for i in range(n):
            if not done[i]:
                all_done = False
                break
        if all_done:
            break

        # (5) Charge a round to each live step; fail those out of budget.
        var any_timed_out = False
        for i in range(n):
            if done[i]:
                continue
            if not started[i] and start_failures[i] == 0:
                continue
            step_rounds[i] += 1
            if step_rounds[i] >= step_max_attempts[i]:
                status[i] = STEP_FAIL
                done[i] = True
                any_timed_out = True
                var carried_detail = outcomes[i].detail.copy()
                if start_failures[i] > 0:
                    outcomes[i] = ValidationOutcome.failed(
                        -1,
                        String("could not start: ")
                        + String(start_failures[i])
                        + String(" consecutive job-creation failure(s) within ")
                        + String(step_max_attempts[i])
                        + String(" round(s) OF ITS OWN — the step never ran, so")
                        + String(" there is no execution to read. Last start")
                        + String(" error: ")
                        + last_start_error[i]
                        + (
                            String("")
                            if attempts[i] == 0
                            else String(" (an earlier attempt DID run and")
                            + String(" reported: ")
                            + outcomes[i].summary
                            + String(")")
                        ),
                        String("") if attempts[i] == 0 else carried_detail,
                    )
                elif attempts[i] > 0:
                    outcomes[i] = ValidationOutcome.failed(
                        outcomes[i].exit_code,
                        String("timeout after ")
                        + String(attempts[i])
                        + String(" attempt(s) within ")
                        + String(step_max_attempts[i])
                        + String(" round(s) OF ITS OWN — last verdict: ")
                        + outcomes[i].summary,
                        carried_detail,
                    )
                else:
                    var live = validators[i].last_observed_state()
                    outcomes[i] = ValidationOutcome.failed(
                        -1,
                        String("timeout: execution did not reach a terminal")
                        + String(" verdict within ")
                        + String(step_max_attempts[i])
                        + String(" round(s) x ")
                        + String(budget.interval_ms)
                        + String("ms = ~")
                        + String(
                            (step_max_attempts[i] * budget.interval_ms) // 1000
                        )
                        + String("s OF ITS OWN (the budget is per step —")
                        + String(" time spent blocked on a dependency is not")
                        + String(" charged here)")
                        + (
                            String("")
                            if live.byte_length() == 0
                            else String(" — ") + live
                        ),
                    )
                reporter.info(
                    String("validate-dag: step '")
                    + names[i]
                    + String("' FAIL (")
                    + (
                        String("could not start")
                        if start_failures[i] > 0
                        else String("timeout")
                    )
                    + String(") — ")
                    + outcomes[i].summary
                )
                _report_failure_output[R](outcomes[i], names[i], reporter)
                _report_failure_run_logs[V, R](
                    validators, i, names[i], reporter
                )

        if any_timed_out:
            continue

        budget.sleep_between()

    var results = List[StepResult]()
    var passed = True
    for i in range(n):
        if status[i] != STEP_PASS:
            passed = False
        results.append(StepResult(names[i].copy(), status[i], outcomes[i].copy()))

    var outcome = DagOutcome(passed, results^)
    reporter.info(
        String("validate-dag: ")
        + outcome.summary()
        + String(" — ")
        + (String("PASS") if passed else String("FAIL"))
    )
    return outcome^


def run_validation_dag[
    V: DagValidator, R: Reporter
](
    mut validators: List[V],
    names: List[String],
    deps: List[List[String]],
    budget: PollBudget,
    mut reporter: R,
    max_jobs: Int = 0,
) raises -> DagOutcome:
    """Run the wave's validate steps as a DAG (`_run_validation_dag_steps` is the
    scheduler contract) AND release every step's cloud resource before returning,
    on every exit path, including the one that raises.

    Teardown is a step of the lifecycle, not a consequence of an observation. After
    the scheduler returns or raises, every validator's `teardown()` is called, each
    preceded by a `TEARDOWN` line stating why it fired (`step_teardown_reason`). A
    teardown fault is reported and never changes a verdict. If the scheduler
    raised, the fault is re-raised after the teardowns; otherwise each
    `StepResult` is stamped with its teardown reason."""
    var fault = String("")
    var outcome = Optional[DagOutcome]()
    try:
        outcome = Optional[DagOutcome](
            _run_validation_dag_steps[V, R](
                validators, names, deps, budget, reporter, max_jobs
            )
        )
    except e:
        fault = String(e)
    var reasons = List[String]()
    for i in range(len(validators)):
        var status_i = STEP_FAIL
        var summary_i = String("")
        if outcome and i < len(outcome.value().results):
            status_i = outcome.value().results[i].status
            summary_i = outcome.value().results[i].outcome.summary.copy()
        var reason = step_teardown_reason(fault, status_i, summary_i^)
        reasons.append(reason.copy())
        try:
            reporter.info(
                String("validate-dag: step '")
                + (names[i] if i < len(names) else String("?"))
                + String("' TEARDOWN — ")
                + reason
            )
        except:
            pass
        try:
            validators[i].teardown()
        except te:
            reporter.info(
                String("validate-dag: step '")
                + (names[i] if i < len(names) else String("?"))
                + String("' teardown did not complete: ")
                + String(te)
                + String(
                    " — the step's verdict is unchanged; any resource left"
                    " standing is a cloud-leak finding, not a gate result"
                )
            )
    if fault.byte_length() > 0:
        raise Error(fault)
    var decided = outcome.value().copy()
    var stamped = List[StepResult]()
    for i in range(len(decided.results)):
        var r = decided.results[i].copy()
        if i < len(reasons):
            r.teardown_reason = reasons[i].copy()
        stamped.append(r^)
    return DagOutcome(decided.passed, stamped^)


struct ScriptedValidator(Validator, Movable, Deinitable):
    """A hermetic `Validator` that replays a scripted list of VALIDATION_* codes,
    one per `run_once`, repeating the last one when the script runs out."""

    var _verdicts: List[Int]
    var _cursor: Int

    def __init__(out self, var verdicts: List[Int]):
        self._verdicts = verdicts^
        self._cursor = 0

    @staticmethod
    def fail_then_pass(fail_count: Int) -> ScriptedValidator:
        """`fail_count` FAILs, then PASS."""
        var v = List[Int]()
        for _ in range(fail_count if fail_count > 0 else 0):
            v.append(VALIDATION_FAIL)
        v.append(VALIDATION_PASS)
        return ScriptedValidator(v^)

    @staticmethod
    def always_fail() -> ScriptedValidator:
        """FAIL on every attempt."""
        var v = List[Int]()
        v.append(VALIDATION_FAIL)
        return ScriptedValidator(v^)

    @staticmethod
    def always_pass() -> ScriptedValidator:
        """PASS on every attempt."""
        var v = List[Int]()
        v.append(VALIDATION_PASS)
        return ScriptedValidator(v^)

    def run_once(mut self) raises -> ValidationOutcome:
        var idx = self._cursor
        if idx >= len(self._verdicts):
            idx = len(self._verdicts) - 1
        var code = self._verdicts[idx]
        self._cursor += 1
        var exit_code = 0 if code == VALIDATION_PASS else 1
        return ValidationOutcome(
            code, exit_code, String("scripted:") + verdict_label(code)
        )

    def attempts_run(self) -> Int:
        """How many times `run_once` ran."""
        return self._cursor


struct _DagEvents(Movable):
    """The shared event list behind a `DagEventLog`."""

    var events: List[String]

    def __init__(out self):
        self.events = List[String]()


struct DagEventLog(Movable, Deinitable):
    """A shared, ordered event log for hermetic DAG tests: `share()` hands each
    scripted validator a handle to the same list, so a test can assert the order
    in which steps started and were polled."""

    var _p: ArcPointer[_DagEvents]

    def __init__(out self):
        self._p = ArcPointer[_DagEvents](_DagEvents())

    def __init__(out self, *, var _share: ArcPointer[_DagEvents]):
        self._p = _share^

    def share(self) -> DagEventLog:
        """Another handle to the same log."""
        return DagEventLog(_share=ArcPointer[_DagEvents](copy=self._p))

    def record(self, event: String):
        """Append `event`."""
        self._p[].events.append(event)

    def count(self) -> Int:
        return len(self._p[].events)

    def at(self, i: Int) -> String:
        return self._p[].events[i]

    def index_of(self, event: String) -> Int:
        """The first index of `event`, or -1."""
        for i in range(len(self._p[].events)):
            if self._p[].events[i] == event:
                return i
        return -1


struct ScriptedDagValidator(DagValidator, Movable, Deinitable):
    """A hermetic `DagValidator`: records `start:<name>` and `poll:<name>` in a
    shared `DagEventLog`, returns `None` from `poll` for `polls_to_terminal` polls,
    then a PASS or FAIL. Always re-arms on `restart`."""

    var _name: String
    var _polls_to_terminal: Int
    var _pass: Bool
    var _poll_count: Int
    var _log: DagEventLog

    def __init__(
        out self,
        name: String,
        var log: DagEventLog,
        polls_to_terminal: Int = 0,
        does_pass: Bool = True,
    ):
        self._name = name
        self._polls_to_terminal = polls_to_terminal if polls_to_terminal > 0 else 0
        self._pass = does_pass
        self._poll_count = 0
        self._log = log^

    def start(mut self) raises:
        self._log.record(String("start:") + self._name)

    def poll(mut self) raises -> Optional[ValidationOutcome]:
        self._log.record(String("poll:") + self._name)
        if self._poll_count < self._polls_to_terminal:
            self._poll_count += 1
            return None
        var code = VALIDATION_PASS if self._pass else VALIDATION_FAIL
        var exit_code = 0 if self._pass else 1
        return Optional[ValidationOutcome](
            ValidationOutcome(
                code, exit_code, String("scripted-dag:") + self._name
            )
        )

    def restart(mut self) raises -> Bool:
        self._poll_count = 0
        return True

    def run_once(mut self) raises -> ValidationOutcome:
        self.start()
        var terminal = self.poll()
        if terminal:
            return terminal.value().copy()
        return ValidationOutcome.indeterminate(
            -1, String("scripted-dag:") + self._name + String(":running")
        )
