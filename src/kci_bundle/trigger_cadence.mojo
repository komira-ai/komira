# =============================================================================
# kci_bundle/trigger_cadence.mojo — the DECLARED cadence of a
#   ReleaseMachine's SCHEDULE trigger, resolved to microseconds.
# =============================================================================
#
# WHAT THIS IS FOR. A merge-from-live step timed once a week keeps security
# patches constantly deployed. A machine declares that cadence as a SCHEDULE trigger; this file is the ONLY
# place that turns the declaration into a number.
#
# ⚠ THIS FILE DOES NOT SCHEDULE ANYTHING, AND MUST NOT LEARN HOW.
# The release CLI (kci) is one-shot — no daemon, no timer, no process that outlives a
# verb. The control plane owns evaluation: the promotion sweep advances a
# per-deployment clock (a deployment track's next auto-update time) by the cadence,
# driven by the ONE cloud tick the install already has. There is deliberately no
# per-customer cloud timer — that would be N_orgs x M_apps scheduler jobs to
# provision, bill and reconcile. So: the release CLI DECLARES, the CP EVALUATES, and the
# seam between them is exactly this function's return value.
#
# ── A CRON IS A SET OF INSTANTS; A CADENCE IS AN INTERVAL ────────────────────
# They are not the same thing, and conflating them is how a scheduler quietly
# fires at the wrong rate. `0 6 5 * *` (06:00 on the 5th of each month) names
# real instants but expresses NO fixed interval — months are 28-31 days. Rather
# than pick a lie (30 days? 31?), this resolver accepts ONLY the strictly
# periodic subset and REJECTS the rest with a message that says why.
#
# ACCEPTED (5 fields: `minute hour dom mon dow`, `dom`/`mon` must be `*`):
#   `0 6 * * 1`   -> 7 days   (weekly — the merge-from-live shape)
#   `0 6 * * *`   -> 1 day    (daily)
#   `0 */6 * * *` -> 6 hours
#   `0 * * * *`   -> 1 hour   (hourly)
#   `*/15 * * * *`-> 15 minutes
#   `* * * * *`   -> 1 minute
#
# REJECTED, each with its own reason:
#   any `dom`/`mon` restriction     — not a fixed interval (month lengths vary)
#   lists / ranges (`1,4` / `1-5`)  — not a single interval
#   a `dow` with a wildcard hour    — "weekly" that fires 24x a week is not weekly
#   `@weekly` / `@daily` macros     — one accepted spelling, not two
#
# Mojo 1.0.0b2 (def-only). No UnsafePointer, no FFI, pure String -> Int64.
# =============================================================================

from kci_bundle_proto.app_bundle import AppBundle

# ── The cadence units, in microseconds ──────────────────────────────────────
comptime MINUTE_US: Int64 = 60 * 1_000_000
comptime HOUR_US: Int64 = 60 * MINUTE_US
comptime DAY_US: Int64 = 24 * HOUR_US

comptime WEEKLY_CADENCE_US: Int64 = 7 * DAY_US
"""The merge-from-live default: seven days. This is the SAME value the control
plane's weekly cadence carries, and it is what a machine that declares no
SCHEDULE trigger falls back to — so the no-trigger path is the plain weekly
cadence."""

# The `TriggerSource.on` arm index for `schedule`. The generated `_oneof0_case`
# is the 1-BASED ARM INDEX in declaration order (git_push 1 / schedule 2 /
# package_published 3), NOT the proto field number (6/7/8). A wrong constant here
# is a SILENT wrong-arm read, never a compile error.
comptime _ARM_SCHEDULE: Int = 2


def _split_ws(s: String) -> List[String]:
    """Split on runs of ASCII space/tab, dropping empties — so `0  6 * * 1` reads
    the same as `0 6 * * 1`."""
    var out = List[String]()
    var cur = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord(" ")) or c == UInt8(ord("\t")):
            if cur.byte_length() > 0:
                out.append(cur.copy())
                cur = String("")
        else:
            cur += chr(Int(c))
    if cur.byte_length() > 0:
        out.append(cur^)
    return out^


def _all_digits(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return False
    return True


def _as_int(s: String) raises -> Int:
    """Parse an all-digit field. The caller has already established `_all_digits`."""
    var n = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        n = n * 10 + Int(b[i] - UInt8(ord("0")))
    return n


def _step_of(field: String) -> Int:
    """The N of a `*/N` step field, or -1 if `field` is not of that form.
    Returns -1 for `*/0` too (a zero step is not a cadence). Byte-indexed: a cron
    field is ASCII by construction, and a non-ASCII byte simply fails the digit
    test below rather than being silently accepted."""
    var b = field.as_bytes()
    if len(b) < 3:
        return -1
    if not (b[0] == UInt8(ord("*")) and b[1] == UInt8(ord("/"))):
        return -1
    var n = 0
    for i in range(2, len(b)):
        var c = b[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return -1
        n = n * 10 + Int(c - UInt8(ord("0")))
    if n <= 0:
        return -1
    return n


def _reject(cron: String, why: String) -> String:
    return (
        String("schedule cron '")
        + cron
        + String("' is not a fixed CADENCE: ")
        + why
        + String(
            ". A cadence must be strictly periodic — the accepted forms are"
            " `M H * * D` (weekly), `M H * * *` (daily), `M */N * * *`,"
            " `M * * * *` (hourly), `*/N * * * *`, and `* * * * *`."
        )
    )


def cron_cadence_us(cron: String) raises -> Int64:
    """Resolve a 5-field cron CADENCE to an interval in microseconds.

    Raises — never guesses — on anything that is not strictly periodic. The
    failure message names the offending field and why it cannot be an interval,
    because the alternative (silently picking 30 days for a monthly cron) is a
    deployment that patches at a rate nobody authored."""
    var f = _split_ws(cron)
    if len(f) != 5:
        raise Error(
            _reject(
                cron,
                String("it has ")
                + String(len(f))
                + String(
                    " field(s), not 5 (`minute hour day-of-month month"
                    " day-of-week`)"
                ),
            )
        )
    var minute = f[0].copy()
    var hour = f[1].copy()
    var dom = f[2].copy()
    var mon = f[3].copy()
    var dow = f[4].copy()

    # (1) A day-of-month or month restriction is NOT an interval — month lengths
    #     vary, so "monthly" has no microsecond value. Rejected, not approximated.
    if dom != String("*"):
        raise Error(
            _reject(
                cron,
                String("the day-of-month field is '")
                + dom
                + String(
                    "'; a monthly recurrence has no fixed length (28-31 days)"
                ),
            )
        )
    if mon != String("*"):
        raise Error(
            _reject(
                cron,
                String("the month field is '")
                + mon
                + String("'; a yearly/seasonal recurrence is not a cadence"),
            )
        )

    # (2) WEEKLY — a single day-of-week. The minute AND hour must be fixed:
    #     `0 * * * 1` fires 24 times every Monday, which is not a weekly cadence,
    #     and silently calling it one is exactly the class of bug this rejects.
    if dow != String("*"):
        if not _all_digits(dow):
            raise Error(
                _reject(
                    cron,
                    String("the day-of-week field is '")
                    + dow
                    + String(
                        "'; only `*` or ONE digit 0-6 is a cadence (a list or"
                        " range names several instants, not one interval)"
                    ),
                )
            )
        var d = _as_int(dow)
        if d > 6:
            raise Error(
                _reject(
                    cron,
                    String("the day-of-week field is ")
                    + String(d)
                    + String("; the legal range is 0-6"),
                )
            )
        if not (_all_digits(minute) and _all_digits(hour)):
            raise Error(
                _reject(
                    cron,
                    String(
                        "a day-of-week is set, so the minute and hour must BOTH"
                        " be fixed values — got minute '"
                    )
                    + minute
                    + String("', hour '")
                    + hour
                    + String("'. Otherwise it fires many times per week"),
                )
            )
        _ = _as_int(minute)
        _ = _as_int(hour)
        return WEEKLY_CADENCE_US

    # (3) DAILY / N-HOURLY — the hour is fixed, or steps.
    if hour != String("*"):
        if not _all_digits(minute):
            raise Error(
                _reject(
                    cron,
                    String(
                        "the hour field constrains the cadence, so the minute"
                        " must be a fixed value — got '"
                    )
                    + minute
                    + String("'"),
                )
            )
        if _all_digits(hour):
            var h = _as_int(hour)
            if h > 23:
                raise Error(
                    _reject(
                        cron,
                        String("the hour field is ")
                        + String(h)
                        + String("; the legal range is 0-23"),
                    )
                )
            return DAY_US
        var hstep = _step_of(hour)
        if hstep < 0:
            raise Error(
                _reject(
                    cron,
                    String("the hour field is '")
                    + hour
                    + String("'; only `*`, ONE digit 0-23, or `*/N` is a cadence"),
                )
            )
        if hstep > 23:
            raise Error(
                _reject(
                    cron,
                    String("the hour step is */")
                    + String(hstep)
                    + String(
                        "; a step above 23 does not repeat evenly across a day"
                    ),
                )
            )
        return Int64(hstep) * HOUR_US

    # (4) HOURLY / N-MINUTELY / MINUTELY — everything above is `*`.
    if minute == String("*"):
        return MINUTE_US
    if _all_digits(minute):
        var m = _as_int(minute)
        if m > 59:
            raise Error(
                _reject(
                    cron,
                    String("the minute field is ")
                    + String(m)
                    + String("; the legal range is 0-59"),
                )
            )
        return HOUR_US
    var mstep = _step_of(minute)
    if mstep < 0:
        raise Error(
            _reject(
                cron,
                String("the minute field is '")
                + minute
                + String("'; only `*`, ONE digit 0-59, or `*/N` is a cadence"),
            )
        )
    if mstep > 59:
        raise Error(
            _reject(
                cron,
                String("the minute step is */")
                + String(mstep)
                + String("; a step above 59 does not repeat evenly across an hour"),
            )
        )
    return Int64(mstep) * MINUTE_US


def schedule_cron_of(bundle: AppBundle) raises -> Optional[String]:
    """The cron of this machine's SCHEDULE trigger, or None if it declares none.

    RAISES ON MORE THAN ONE. A machine has ONE merge-from-live cadence: the
    control plane advances ONE next auto-update time per deployment, so two
    declared schedules cannot both be honored. Silently taking the first (or the
    shortest) would make which one wins a property of authoring order. If a
    machine ever legitimately needs two cadences, that is a design change with a
    place to put the second clock — not a tie-break hidden in a resolver."""
    var found: Optional[String] = None
    var found_name = String("")
    for i in range(len(bundle.triggers)):
        ref t = bundle.triggers[i]
        if t._oneof0_case != _ARM_SCHEDULE:
            continue
        if found:
            raise Error(
                "machine '"
                + bundle.name
                + "' declares MORE THAN ONE schedule trigger ('"
                + found_name
                + "' and '"
                + t.name
                + "'). A machine has exactly one merge-from-live cadence — the"
                " control plane keeps ONE clock per deployment, so a second"
                " schedule has nowhere to be evaluated."
            )
        found = Optional[String](t.schedule.value().cron.copy())
        found_name = t.name.copy()
    return found^


def machine_cadence_us(bundle: AppBundle) raises -> Int64:
    """The cadence the control plane should advance this machine's deployments by.

    The DECLARED schedule when the machine authors one; `WEEKLY_CADENCE_US`
    otherwise — so a machine with no SCHEDULE trigger gets the weekly default.

    Raises on a malformed cron or on two declared schedules (see the two callees).
    A machine that cannot say WHEN must not silently default to weekly: it said
    something, and what it said did not parse."""
    var cron = schedule_cron_of(bundle)
    if not cron:
        return WEEKLY_CADENCE_US
    return cron_cadence_us(cron.value())
