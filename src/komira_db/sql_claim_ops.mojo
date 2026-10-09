# =============================================================================
# komira_db/sql_claim_ops.mojo — the SQL implementation of the neutral claim.
# =============================================================================
#
# `sql_op_claim_rows` and its extra-SET renderer, split out of
# `sql_neutral_ops.mojo` (which re-exports `sql_op_claim_rows`) to keep each file
# small. Same contract as there: one shared renderer, `DB: SqlDatabase`
# parametric, byte-identical to the hand-written JobStore claim SQL.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.db_value import DbValue
from komira_db.db_row import DbRows
from komira_db.neutral_ops import (
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
    POD_NAME_ID_TAIL_LEN,
)


def sql_op_claim_rows[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    n: Int,
    filter: Filter,
    order: List[Order],
    phase_col: String,
    from_phase: String,
    to_phase: String,
    extra: List[DbColVal],
    per_row_mint: PodNameMinter,
    bump_version_col: Optional[String],
    now_cols: List[String],
) raises -> DbRows:
    """The neutral claim over the driver's native `claim_pending`. Builds the
    `extra_set` string (the per-row pod_name mint + the `extra` SET terms + the
    `version = version + 1` bump + each `now_cols` `= <now_expr>` stamp) and
    the bind params, then hands to `claim_pending`. The pod_name term binds
    NOTHING (see `_render_pod_name_term`); the `extra` terms
    own every placeholder from the first. `filter` / `order` are
    accepted for surface generality but the concurrent claim's pending/order is
    owned by `claim_pending` (WHERE <phase_col>=<from> ORDER BY created_at) — the
    JobStore claim uses exactly that fixed shape, so we thread the phase COLUMN
    NAME (`phase_col`), from/to phase, and the extra_set. A caller whose queue
    column is named `"phase"` (JobStore, an outbound queue) gets the default
    shape; a caller with a different column name
    threads it here and it lands in `claim_pending`'s WHERE + SET."""
    _ = filter
    _ = order
    var extra_set = _render_claim_extra_set[DB](
        per_row_mint, extra, bump_version_col, now_cols
    )
    var claim_params = List[DbValue]()
    # ⭐ THE MINT BINDS NOTHING. `pod_name` is a pure function of the
    # row's own `id`, rendered entirely server-side, so the extra terms own
    # every placeholder from the first. RAW-EXPR extra terms (`version =
    # version + 1`, `updated_at = <now_expr>`) bind NOTHING either.
    for i in range(len(extra)):
        if not extra[i].is_raw_expr():
            claim_params.append(extra[i].val.copy())
    return db.claim_pending[RT](
        reactor, table, n, from_phase, to_phase, extra_set, claim_params, phase_col
    )


def _unknown_kind(t: DbColVal) -> String:
    """The refusal for a SET term whose `kind` is no COLVAL_* shape."""
    return (
        String("SET term \"")
        + t.col
        + String("\": kind ")
        + String(Int(t.kind))
        + String(" is not COLVAL_BIND, COLVAL_COALESCE or COLVAL_RAW_EXPR")
    )


def _render_claim_extra_set[DB: SqlDatabase](
    mint: PodNameMinter,
    extra: List[DbColVal],
    bump_version_col: Optional[String],
    now_cols: List[String],
) raises -> String:
    """Render the claim's `extra_set` clause: the per-row pod_name mint (if
    active) + each `extra` SET term (`col = $n` binds / `col = <expr>` raw) +
    the `version = version + 1` bump (`bump_version_col`) + each `now_cols`
    `= <now_expr>` stamp.

    The pod_name mint is the server-side spelling of `derive_pod_name`:
      * pgstore: `pod_name = pgstore_pod_name('<prefix>')`
      * pg:  `pod_name = CONCAT('<prefix>', '-', RIGHT(id::text, 12))`
      * sqlite: `pod_name = ('<prefix>' || '-' || lower(substr(hex(id), 21,
             12)))`
    then `, ` + each `extra` term, then `, version = version + 1` (when
    `bump_version_col`), then `, <col> = <now_expr>` per `now_cols`. The version
    bump + now-stamp are FIRST-CLASS params (not raw-expr `extra` terms) so the
    NEUTRAL caller (JobStore on the `Database` bound) never needs `now_expr()` —
    the renderer supplies the dialect now-expr here. The FULL extra_set matches
    JobStore's `pod_name = <expr>, version = version + 1, updated_at =
    <now_expr>`."""
    var out = String()
    var first = True
    # ⭐ EXTRA BINDS START AT placeholder(0). The mint binds nothing, so no
    # placeholder is reserved for it — whether the mint is active or not, the
    # rendered placeholders and the params `claim_rows` binds stay in step.
    var bind = 0
    if mint.is_active():
        out += _render_pod_name_term[DB](mint.prefix)
        first = False
    for i in range(len(extra)):
        ref e = extra[i]
        if not first:
            out += String(", ")
        first = False
        if e.is_raw_expr():
            # A raw-SQL expression term (`version = version + 1`, `updated_at =
            # <now_expr>`) — NO bind; render the literal expression.
            out += e.col + String(" = ") + e.val.as_text()
        elif not e.binds_a_param():
            raise Error(_unknown_kind(e))
        else:
            # A bound value term: `col = $bind`.
            out += e.col + String(" = ") + DB.placeholder(bind)
            bind += 1
    if bump_version_col:
        var vc = bump_version_col.value()
        if not first:
            out += String(", ")
        first = False
        out += vc + String(" = ") + vc + String(" + 1")
    for i in range(len(now_cols)):
        if not first:
            out += String(", ")
        first = False
        out += now_cols[i] + String(" = ") + DB.now_expr()
    return out^


def _render_pod_name_term[DB: SqlDatabase](prefix: String) raises -> String:
    """Render ONLY the `pod_name = <expr>` term of the claim extra_set: the
    server-side spelling of `derive_pod_name(prefix, id_text)` —
    `<prefix>-<last POD_NAME_ID_TAIL_LEN chars of the id text, lowercased>`.

    ⛔⛔ IT BINDS NOTHING, AND THAT IS THE POINT. A bound CSPRNG suffix would
    make the placement name unrecomputable from the job id — so a job manager
    that crashed between the `pod_name` write and the `create` could never
    address the unit that create may have left behind. Every term below is a
    pure function of the row's own `id`. Do NOT add a bind here: a parameter is, by
    construction, something the recovery path does not have.

    ⚠ THE THREE DIALECTS MUST AGREE WITH `derive_pod_name` BYTE FOR BYTE, which
    is what `lower(...)` is doing on the sqlite arm: `hex()` answers in
    UPPERCASE where pg's `id::text` is lowercase, so without it the same job id
    would produce two different names on two backends (and an uppercase character is
    illegal in a Cloud Run resource name). The 12-character tail is the
    hyphenated id's FINAL group, the one slice carrying no hyphen — which is why
    a raw `RIGHT(id::text, N)` and a raw `substr(hex(id), k, N)` can be equal at
    all."""
    if DB.dialect() == String("pgstore"):
        return (
            String("pod_name = pgstore_pod_name('") + prefix + String("')")
        )
    if DB.placeholder(0) == String("$1"):
        # pg dialect. `id::text` is the lowercase hyphenated form; its last 12
        # characters are the final `8-4-4-4-12` group.
        return (
            String("pod_name = CONCAT('")
            + prefix
            + String("', '-', RIGHT(id::text, ")
            + String(POD_NAME_ID_TAIL_LEN)
            + String("))")
        )
    # sqlite dialect. `id` is a 16-byte BLOB, so `hex(id)` is 32 UPPERCASE hex
    # characters with no hyphens: the final group starts at 1-based char
    # 32 - 12 + 1 = 21.
    return (
        String("pod_name = ('")
        + prefix
        + String("' || '-' || lower(substr(hex(id), ")
        + String(32 - POD_NAME_ID_TAIL_LEN + 1)
        + String(", ")
        + String(POD_NAME_ID_TAIL_LEN)
        + String(")))")
    )
