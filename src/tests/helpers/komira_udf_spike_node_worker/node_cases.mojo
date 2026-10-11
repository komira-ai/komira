# The shared conformance cases (komira_udf_spike_abi/cases) as the
# komira-test/node worker runtime runs them.
#
# The corpus names each fixture by a bare name (`double`) that each runtime
# implements in its language (design section 6.3). This runtime's entries
# are `<bundle>#<export>`, so every entry becomes `fixtures.mjs#<name>`: the
# esbuild bundle of udf/fixtures.ts.
#
# Sixty-six cases are left out (runtime_fault_cases): each one's fixture is
# an act at the C ABI, which only a runtime library can commit, or a per-row
# function that raises by its row's position; user code cannot express
# either. In this runtime the proxy, not user code, builds every
# array the host sees, moves and releases the inputs, and fills the error, so
# a TypeScript function cannot leave an input unmoved, fill an error on OK,
# name a row outside its batch, leave the error's row as the host set it,
# hand back a malformed or sliced output array or table, move a child out of
# the argument struct, read the schema flags, refuse a second group set, or
# answer after its own error. komira-test/echo has those fixtures.
# Every case user code can express runs, among them the frame that never
# ends (an endless generator is user code).

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases

comptime FIXTURE_BUNDLE = "fixtures.mjs"


def runtime_fault_cases() -> List[String]:
    """The cases whose fixtures user code cannot express (above)."""
    return [
        # inputs not moved, an error filled on OK, an error row outside the batch
        # or left as the host set it
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
        "error_row_left_unset",
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
        "frame_output_sliced_offset",
        "table_null_count_unknown",
        # a frame that yields its two-column input as a one-column table:
        # the proxy refuses the input, and user code cannot yield a table of
        # another width (worker/frames.mjs, outputOf)
        "frame_fault_then_raise",
        # a per-row function that raises by its row's position, not its
        # value: a per-row result may not depend on where it sits in the
        # batch (design section 3.4, rule 3), and a TypeScript function sees
        # only its arguments; raise_on_row_3 here raises on the value 3, and
        # test_node_worker checks the error row under PROPAGATE with it
        "error_row_at_least_edge",
        "scalar_propagate_error_row",
        # aggregate outputs the proxy sizes: a state column one row long, a
        # result one row short
        "agg_state_long_by_one",
        "agg_finish_short_by_one",
        # acts at the ABI: a child moved out of the argument struct, the schema
        # flags read, a second group set refused, a frame answering after its
        # error
        "child_moved_out",
        "schema_flags_exported",
        "agg_partials_on_own_instances",
        "frame_no_next_after_error",
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
