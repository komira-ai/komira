// The EXPLAIN ANALYZE arm flag.
//
// `explain_analyze_collect.ea_armed()` is read at every collection seam, one
// of which every pipeline breaker passes through, so the disarmed read must be
// cheap. A Mojo `_Global` lookup is a `raises`, string-keyed registry lookup
// inside a `try`/`except`; this is a TU-static read with a relaxed atomic load.
//
// There is deliberately no getenv here: arming is SCOPED to one
// `ctx.explain_analyze(...)` call, never environment-driven, so the load has
// nothing to initialise.
//
// Only the ARM FLAG lives here. The per-kind slot table stays in Mojo
// `_Global` storage: it is touched only on the ARMED path, where a registry
// lookup is irrelevant against the query it is measuring.

static int _ea_armed_flag = 0;

// The disarmed hot read. One relaxed load; no branch, no getenv, no
// allocation.
int komira_ea_armed(void) {
    return __atomic_load_n(&_ea_armed_flag, __ATOMIC_RELAXED);
}

// Arm (v != 0) / disarm (v == 0). Called twice per `ctx.explain_analyze` call.
int komira_ea_set_armed(int v) {
    __atomic_store_n(&_ea_armed_flag, v ? 1 : 0, __ATOMIC_RELAXED);
    return 0;
}
