# The shared conformance cases (komira_udf_spike_abi/cases) as the
# komira-test/node worker runtime runs them.
#
# The corpus names each fixture by a bare name (`double`) that each runtime
# implements in its language (design section 6.3). This runtime's entries
# are `<bundle>#<export>`, so every entry becomes `fixtures.mjs#<name>`: the
# esbuild bundle of udf/fixtures.ts.
#
# Seven cases are left out: their fixtures are runtime bugs (an output with
# the wrong layout, an input not moved, OK without an output, an output on
# another device, a null_count that lies, `out` left set on an error, an
# aggregate input not moved). User code cannot commit them; only a runtime
# written to break the ABI can, which is what komira-test/echo-broken is for.
# The frame that never ends stays in: an endless generator is user code.

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases

comptime FIXTURE_BUNDLE = "fixtures.mjs"


def runtime_fault_cases() -> List[String]:
    """The cases whose fixtures are runtime bugs (above)."""
    return [
        "bad_output_layout",
        "fault_agg_args_not_moved",
        "fault_args_not_moved",
        "fault_null_count_contradicts_validity",
        "fault_ok_without_output",
        "fault_out_set_on_error",
        "fault_output_not_on_cpu",
    ]


def node_cases(dir: String) raises -> List[Case]:
    """The cases under `dir` but the runtime-fault ones, each entry
    rewritten to `fixtures.mjs#<name>`. Raises UDF_CASES_CHANGED when a name
    in runtime_fault_cases() is not in the corpus (the list went stale)."""
    var all = load_cases(dir)
    var faults = runtime_fault_cases()
    var out = List[Case]()
    var dropped = 0
    for i in range(len(all)):
        var c = all[i].copy()
        if c.name in faults:
            dropped += 1
            continue
        if c.spec.entry != "":
            c.spec.entry = FIXTURE_BUNDLE + "#" + c.spec.entry
        out.append(c^)
    if dropped != len(faults):
        raise Error(
            "UDF_CASES_CHANGED: " + String(dropped) + " of the "
            + String(len(faults)) + " runtime-fault cases are in " + dir
        )
    return out^
