# The shared conformance cases (komira_udf_spike_abi/cases) as the
# komira-test/node worker runtime runs them.
#
# The corpus names each fixture by a bare name (`double`) that each runtime
# implements in its language (design section 6.3). This runtime's entries
# are `<bundle>#<export>`, so every entry becomes `fixtures.mjs#<name>`: the
# esbuild bundle of udf/fixtures.ts.
#
# Sixty-three cases are left out (runtime_fault_cases): each one's fixture
# is an act at the C ABI, which only a runtime library can commit. In this
# runtime the proxy, not user code, builds every array the host sees, moves
# and releases the inputs, and fills the error, so a TypeScript function cannot
# leave an input unmoved, fill an error on OK, name a row outside its batch,
# hand back a malformed or sliced output array or table, move a child out
# of the argument struct, read the schema flags, or refuse a second group
# set. komira-test/echo has those fixtures. Where a case's fixture is a
# runtime act whose outcome plain user code also reaches, the case runs
# with the user code: raise_row_unset is a batch function that throws (the
# proxy reports row -1), raise_again a generator that throws (the worker
# ends the frame, so nothing answers after the error). The frame that
# never ends runs too (an endless generator is user code).

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases

comptime FIXTURE_BUNDLE = "fixtures.mjs"


def runtime_fault_cases() -> List[String]:
    """The cases whose fixtures user code cannot express (above)."""
    return [
        # inputs not moved, an error filled on OK, an error row outside the batch
        "fault_args_not_moved",
        "fault_args_not_moved_on_error",
        "fault_agg_args_not_moved",
        "fault_agg_args_not_moved_on_error",
        "fault_agg_group_ids_not_moved",
        "fault_agg_group_ids_not_moved_on_error",
        "fault_agg_states_not_moved",
        "fault_agg_states_not_moved_on_error",
        "fault_frame_input_not_moved",
        "fault_frame_input_not_moved_on_error",
        "error_released_on_ok",
        "frame_error_released_on_ok",
        "fault_error_row_below_minus_one",
        "fault_error_row_minus_two",
        "fault_error_row_past_batch",
        "fault_error_row_past_batch_propagate",
        # output columns the proxy builds: malformed, or a legal layout it never
        # writes (sliced, null_count -1, no data buffer)
        "bad_output_layout",
        "fault_ok_without_output",
        "fault_out_set_on_error",
        "fault_output_not_on_cpu",
        "fault_null_count_contradicts_validity",
        "fault_output_buffers_null",
        "fault_output_data_null",
        "fault_output_data_null_one_row",
        "fault_output_device_id",
        "fault_output_dictionary",
        "fault_output_n_buffers_3",
        "fault_output_n_children_1",
        "fault_output_negative_length",
        "fault_output_negative_offset",
        "fault_output_null_count_below",
        "fault_output_null_count_zero",
        "fault_output_release_keeps_slot",
        "fault_output_sync_event",
        "output_sliced_offset",
        "output_null_count_unknown",
        "output_empty_without_data",
        # output tables the proxy builds, the same way
        "fault_table_buffers_null",
        "fault_table_child_null",
        "fault_table_child_released",
        "fault_table_child_short",
        "fault_table_device",
        "fault_table_dictionary",
        "fault_table_n_buffers_0",
        "fault_table_n_buffers_2",
        "fault_table_n_children_0",
        "fault_table_n_children_2",
        "fault_table_negative_length",
        "fault_table_negative_offset",
        "fault_table_null_count_below",
        "fault_table_null_count_lies",
        "fault_table_null_count_zero",
        "fault_table_null_rows",
        "fault_table_out_on_error",
        "fault_table_release_keeps_slot",
        "frame_output_sliced_offset",
        "table_null_count_unknown",
        # a frame that yields its two-column input as a one-column table:
        # the proxy refuses the input, and user code cannot yield a table of
        # another width (worker/frames.mjs, outputOf)
        "frame_fault_then_raise",
        # aggregate outputs the proxy sizes: a state column one row long, a
        # result one row short
        "agg_state_long_by_one",
        "agg_finish_short_by_one",
        # acts at the ABI: a child moved out of the argument struct, the schema
        # flags read, a second group set refused
        "child_moved_out",
        "schema_flags_exported",
        "agg_partials_on_own_instances",
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
