# The Mojo mirror (_cabi.mojo, contract.mojo, wire.mojo) against the C
# compiler's layout of komira_udf_runtime.h and komira_udf_wire.h, row by row
# (native/layout_probe.c lists the rows).
#
# Defects caught: a struct field added, dropped, reordered or retyped on one
# side (a size or offset differs); a constant renumbered on one side; a row
# one side has and the other lacks; a table entry appended to the header
# without a probe row (the probe's `table_slots`, derived from sizeof, then
# differs from its count of `slot` rows).
# Mutant planted: CUdfCapabilities' `udf_class` and `features` swapped in the
# Mojo mirror: red ("offsetof komira_udf_capabilities.features: C 52, Mojo
# 56"); the conformance tests go red with it, reading the class from the
# wrong word.

from std.sys import size_of
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi._cabi import (
    CArrowArray,
    CArrowArrayStream,
    CArrowDeviceArray,
    CArrowDeviceArrayStream,
    CArrowSchema,
    CUdfCall,
    CUdfCapabilities,
    CUdfError,
    CUdfHost,
    CUdfRuntime,
    CUdfSpec,
    CUdfWireHeader,
    c_layout_edges,
    c_layout_rows,
    free_zeroed,
    zeroed,
)
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.wire import *


struct Rows:
    var names: List[String]
    var values: List[Int64]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[Int64]()

    def add(mut self, name: String, v: Int):
        self.names.append(name)
        self.values.append(Int64(v))


def _schema_rows(mut r: Rows):
    var p = zeroed(size_of[CArrowSchema]()).bitcast[CArrowSchema]()
    var b = Int(p)
    r.add("sizeof ArrowSchema", size_of[CArrowSchema]())
    r.add("offsetof ArrowSchema.format", Int(UnsafePointer(to=p[].format)) - b)
    r.add("offsetof ArrowSchema.name", Int(UnsafePointer(to=p[].name)) - b)
    r.add("offsetof ArrowSchema.metadata", Int(UnsafePointer(to=p[].metadata)) - b)
    r.add("offsetof ArrowSchema.flags", Int(UnsafePointer(to=p[].flags)) - b)
    r.add("offsetof ArrowSchema.n_children", Int(UnsafePointer(to=p[].n_children)) - b)
    r.add("offsetof ArrowSchema.children", Int(UnsafePointer(to=p[].children)) - b)
    r.add("offsetof ArrowSchema.dictionary", Int(UnsafePointer(to=p[].dictionary)) - b)
    r.add("offsetof ArrowSchema.release", Int(UnsafePointer(to=p[].release)) - b)
    r.add("offsetof ArrowSchema.private_data", Int(UnsafePointer(to=p[].private_data)) - b)
    free_zeroed(p.bitcast[NoneType]())


def _array_rows(mut r: Rows):
    var p = zeroed(size_of[CArrowArray]()).bitcast[CArrowArray]()
    var b = Int(p)
    r.add("sizeof ArrowArray", size_of[CArrowArray]())
    r.add("offsetof ArrowArray.length", Int(UnsafePointer(to=p[].length)) - b)
    r.add("offsetof ArrowArray.null_count", Int(UnsafePointer(to=p[].null_count)) - b)
    r.add("offsetof ArrowArray.offset", Int(UnsafePointer(to=p[].offset)) - b)
    r.add("offsetof ArrowArray.n_buffers", Int(UnsafePointer(to=p[].n_buffers)) - b)
    r.add("offsetof ArrowArray.n_children", Int(UnsafePointer(to=p[].n_children)) - b)
    r.add("offsetof ArrowArray.buffers", Int(UnsafePointer(to=p[].buffers)) - b)
    r.add("offsetof ArrowArray.children", Int(UnsafePointer(to=p[].children)) - b)
    r.add("offsetof ArrowArray.dictionary", Int(UnsafePointer(to=p[].dictionary)) - b)
    r.add("offsetof ArrowArray.release", Int(UnsafePointer(to=p[].release)) - b)
    r.add("offsetof ArrowArray.private_data", Int(UnsafePointer(to=p[].private_data)) - b)
    free_zeroed(p.bitcast[NoneType]())


def _stream_rows(mut r: Rows):
    var p = zeroed(size_of[CArrowArrayStream]()).bitcast[CArrowArrayStream]()
    var b = Int(p)
    r.add("sizeof ArrowArrayStream", size_of[CArrowArrayStream]())
    r.add("offsetof ArrowArrayStream.get_schema", Int(UnsafePointer(to=p[].get_schema)) - b)
    r.add("offsetof ArrowArrayStream.get_next", Int(UnsafePointer(to=p[].get_next)) - b)
    r.add("offsetof ArrowArrayStream.get_last_error", Int(UnsafePointer(to=p[].get_last_error)) - b)
    r.add("offsetof ArrowArrayStream.release", Int(UnsafePointer(to=p[].release)) - b)
    r.add("offsetof ArrowArrayStream.private_data", Int(UnsafePointer(to=p[].private_data)) - b)
    free_zeroed(p.bitcast[NoneType]())
    var d = zeroed(size_of[CArrowDeviceArray]()).bitcast[CArrowDeviceArray]()
    var db = Int(d)
    r.add("sizeof ArrowDeviceArray", size_of[CArrowDeviceArray]())
    r.add("offsetof ArrowDeviceArray.array", Int(UnsafePointer(to=d[].array)) - db)
    r.add("offsetof ArrowDeviceArray.device_id", Int(UnsafePointer(to=d[].device_id)) - db)
    r.add("offsetof ArrowDeviceArray.device_type", Int(UnsafePointer(to=d[].device_type)) - db)
    r.add("offsetof ArrowDeviceArray.sync_event", Int(UnsafePointer(to=d[].sync_event)) - db)
    r.add("offsetof ArrowDeviceArray.reserved", Int(UnsafePointer(to=d[].reserved)) - db)
    free_zeroed(d.bitcast[NoneType]())
    var s = zeroed(size_of[CArrowDeviceArrayStream]()).bitcast[CArrowDeviceArrayStream]()
    var sb = Int(s)
    r.add("sizeof ArrowDeviceArrayStream", size_of[CArrowDeviceArrayStream]())
    r.add("offsetof ArrowDeviceArrayStream.device_type", Int(UnsafePointer(to=s[].device_type)) - sb)
    r.add("offsetof ArrowDeviceArrayStream.get_schema", Int(UnsafePointer(to=s[].get_schema)) - sb)
    r.add("offsetof ArrowDeviceArrayStream.get_next", Int(UnsafePointer(to=s[].get_next)) - sb)
    r.add("offsetof ArrowDeviceArrayStream.get_last_error", Int(UnsafePointer(to=s[].get_last_error)) - sb)
    r.add("offsetof ArrowDeviceArrayStream.release", Int(UnsafePointer(to=s[].release)) - sb)
    r.add("offsetof ArrowDeviceArrayStream.private_data", Int(UnsafePointer(to=s[].private_data)) - sb)
    free_zeroed(s.bitcast[NoneType]())


def _udf_rows(mut r: Rows):
    var e = zeroed(size_of[CUdfError]()).bitcast[CUdfError]()
    var eb = Int(e)
    r.add("sizeof komira_udf_error", size_of[CUdfError]())
    r.add("offsetof komira_udf_error.struct_size", Int(UnsafePointer(to=e[].struct_size)) - eb)
    r.add("offsetof komira_udf_error.code", Int(UnsafePointer(to=e[].code)) - eb)
    r.add("offsetof komira_udf_error.message", Int(UnsafePointer(to=e[].message)) - eb)
    r.add("offsetof komira_udf_error.user_trace", Int(UnsafePointer(to=e[].user_trace)) - eb)
    r.add("offsetof komira_udf_error.row", Int(UnsafePointer(to=e[].row)) - eb)
    r.add("offsetof komira_udf_error.group", Int(UnsafePointer(to=e[].group)) - eb)
    r.add("offsetof komira_udf_error.release", Int(UnsafePointer(to=e[].release)) - eb)
    r.add("offsetof komira_udf_error.private_data", Int(UnsafePointer(to=e[].private_data)) - eb)
    free_zeroed(e.bitcast[NoneType]())
    var h = zeroed(size_of[CUdfHost]()).bitcast[CUdfHost]()
    var hb = Int(h)
    r.add("sizeof komira_udf_host", size_of[CUdfHost]())
    r.add("offsetof komira_udf_host.struct_size", Int(UnsafePointer(to=h[].struct_size)) - hb)
    r.add("offsetof komira_udf_host.abi_major", Int(UnsafePointer(to=h[].abi_major)) - hb)
    r.add("offsetof komira_udf_host.abi_minor", Int(UnsafePointer(to=h[].abi_minor)) - hb)
    r.add("offsetof komira_udf_host.host_data", Int(UnsafePointer(to=h[].host_data)) - hb)
    r.add("offsetof komira_udf_host.mem_reserve", Int(UnsafePointer(to=h[].mem_reserve)) - hb)
    r.add("offsetof komira_udf_host.mem_release", Int(UnsafePointer(to=h[].mem_release)) - hb)
    r.add("offsetof komira_udf_host.now_ns", Int(UnsafePointer(to=h[].now_ns)) - hb)
    r.add("offsetof komira_udf_host.log", Int(UnsafePointer(to=h[].log)) - hb)
    free_zeroed(h.bitcast[NoneType]())
    var c = zeroed(size_of[CUdfCapabilities]()).bitcast[CUdfCapabilities]()
    var cb = Int(c)
    r.add("sizeof komira_udf_capabilities", size_of[CUdfCapabilities]())
    r.add("offsetof komira_udf_capabilities.struct_size", Int(UnsafePointer(to=c[].struct_size)) - cb)
    r.add("offsetof komira_udf_capabilities.runtime_id", Int(UnsafePointer(to=c[].runtime_id)) - cb)
    r.add("offsetof komira_udf_capabilities.runtime_abi", Int(UnsafePointer(to=c[].runtime_abi)) - cb)
    r.add("offsetof komira_udf_capabilities.max_descriptor_version", Int(UnsafePointer(to=c[].max_descriptor_version)) - cb)
    r.add("offsetof komira_udf_capabilities.shapes", Int(UnsafePointer(to=c[].shapes)) - cb)
    r.add("offsetof komira_udf_capabilities.threading", Int(UnsafePointer(to=c[].threading)) - cb)
    r.add("offsetof komira_udf_capabilities.thread_affine", Int(UnsafePointer(to=c[].thread_affine)) - cb)
    r.add("offsetof komira_udf_capabilities.transports", Int(UnsafePointer(to=c[].transports)) - cb)
    r.add("offsetof komira_udf_capabilities.hosting", Int(UnsafePointer(to=c[].hosting)) - cb)
    r.add("offsetof komira_udf_capabilities.devices", Int(UnsafePointer(to=c[].devices)) - cb)
    r.add("offsetof komira_udf_capabilities.features", Int(UnsafePointer(to=c[].features)) - cb)
    r.add("offsetof komira_udf_capabilities.udf_class", Int(UnsafePointer(to=c[].udf_class)) - cb)
    r.add("offsetof komira_udf_capabilities.global_lock", Int(UnsafePointer(to=c[].global_lock)) - cb)
    free_zeroed(c.bitcast[NoneType]())


def _spec_rows(mut r: Rows):
    var s = zeroed(size_of[CUdfSpec]()).bitcast[CUdfSpec]()
    var b = Int(s)
    r.add("sizeof komira_udf_spec", size_of[CUdfSpec]())
    r.add("offsetof komira_udf_spec.struct_size", Int(UnsafePointer(to=s[].struct_size)) - b)
    r.add("offsetof komira_udf_spec.shape", Int(UnsafePointer(to=s[].shape)) - b)
    r.add("offsetof komira_udf_spec.form", Int(UnsafePointer(to=s[].form)) - b)
    r.add("offsetof komira_udf_spec.entry", Int(UnsafePointer(to=s[].entry)) - b)
    r.add("offsetof komira_udf_spec.descriptor_version", Int(UnsafePointer(to=s[].descriptor_version)) - b)
    r.add("offsetof komira_udf_spec.descriptor", Int(UnsafePointer(to=s[].descriptor)) - b)
    r.add("offsetof komira_udf_spec.descriptor_len", Int(UnsafePointer(to=s[].descriptor_len)) - b)
    r.add("offsetof komira_udf_spec.args", Int(UnsafePointer(to=s[].args)) - b)
    r.add("offsetof komira_udf_spec.result", Int(UnsafePointer(to=s[].result)) - b)
    r.add("offsetof komira_udf_spec.state", Int(UnsafePointer(to=s[].state)) - b)
    r.add("offsetof komira_udf_spec.null_mode", Int(UnsafePointer(to=s[].null_mode)) - b)
    r.add("offsetof komira_udf_spec.stability", Int(UnsafePointer(to=s[].stability)) - b)
    r.add("offsetof komira_udf_spec.code_root", Int(UnsafePointer(to=s[].code_root)) - b)
    r.add("offsetof komira_udf_spec.n_code", Int(UnsafePointer(to=s[].n_code)) - b)
    r.add("offsetof komira_udf_spec.code_roles", Int(UnsafePointer(to=s[].code_roles)) - b)
    r.add("offsetof komira_udf_spec.code_sha256", Int(UnsafePointer(to=s[].code_sha256)) - b)
    free_zeroed(s.bitcast[NoneType]())
    var c = zeroed(size_of[CUdfCall]()).bitcast[CUdfCall]()
    var cb = Int(c)
    r.add("sizeof komira_udf_call", size_of[CUdfCall]())
    r.add("offsetof komira_udf_call.struct_size", Int(UnsafePointer(to=c[].struct_size)) - cb)
    r.add("offsetof komira_udf_call.deadline_ns", Int(UnsafePointer(to=c[].deadline_ns)) - cb)
    r.add("offsetof komira_udf_call.call_id", Int(UnsafePointer(to=c[].call_id)) - cb)
    r.add("offsetof komira_udf_call.cancel", Int(UnsafePointer(to=c[].cancel)) - cb)
    free_zeroed(c.bitcast[NoneType]())


def _table_rows(mut r: Rows):
    var t = zeroed(size_of[CUdfRuntime]()).bitcast[CUdfRuntime]()
    var b = Int(t)
    r.add("sizeof komira_udf_runtime", size_of[CUdfRuntime]())
    r.add("offsetof komira_udf_runtime.struct_size", Int(UnsafePointer(to=t[].struct_size)) - b)
    r.add("offsetof komira_udf_runtime.abi_major", Int(UnsafePointer(to=t[].abi_major)) - b)
    r.add("offsetof komira_udf_runtime.abi_minor", Int(UnsafePointer(to=t[].abi_minor)) - b)
    r.add("slot describe", Int(UnsafePointer(to=t[].describe)) - b)
    r.add("slot validate", Int(UnsafePointer(to=t[].validate)) - b)
    r.add("slot load", Int(UnsafePointer(to=t[].load)) - b)
    r.add("slot unload", Int(UnsafePointer(to=t[].unload)) - b)
    r.add("slot open_context", Int(UnsafePointer(to=t[].open_context)) - b)
    r.add("slot close_context", Int(UnsafePointer(to=t[].close_context)) - b)
    r.add("slot open_instance", Int(UnsafePointer(to=t[].open_instance)) - b)
    r.add("slot close_instance", Int(UnsafePointer(to=t[].close_instance)) - b)
    r.add("slot call_batch", Int(UnsafePointer(to=t[].call_batch)) - b)
    r.add("slot frame_open", Int(UnsafePointer(to=t[].frame_open)) - b)
    r.add("slot frame_next", Int(UnsafePointer(to=t[].frame_next)) - b)
    r.add("slot frame_close", Int(UnsafePointer(to=t[].frame_close)) - b)
    r.add("slot agg_open", Int(UnsafePointer(to=t[].agg_open)) - b)
    r.add("slot agg_update", Int(UnsafePointer(to=t[].agg_update)) - b)
    r.add("slot agg_merge", Int(UnsafePointer(to=t[].agg_merge)) - b)
    r.add("slot agg_state", Int(UnsafePointer(to=t[].agg_state)) - b)
    r.add("slot agg_finish", Int(UnsafePointer(to=t[].agg_finish)) - b)
    r.add("slot agg_close", Int(UnsafePointer(to=t[].agg_close)) - b)
    r.add("slot shutdown", Int(UnsafePointer(to=t[].shutdown)) - b)
    r.add("slot memory_report", Int(UnsafePointer(to=t[].memory_report)) - b)
    r.add("table_slots", (size_of[CUdfRuntime]() - (Int(UnsafePointer(to=t[].describe)) - b)) // 8)
    free_zeroed(t.bitcast[NoneType]())
    var w = zeroed(size_of[CUdfWireHeader]()).bitcast[CUdfWireHeader]()
    var wb = Int(w)
    r.add("sizeof komira_udf_wire_header", size_of[CUdfWireHeader]())
    r.add("offsetof komira_udf_wire_header.magic", Int(UnsafePointer(to=w[].magic)) - wb)
    r.add("offsetof komira_udf_wire_header.op", Int(UnsafePointer(to=w[].op)) - wb)
    r.add("offsetof komira_udf_wire_header.request_id", Int(UnsafePointer(to=w[].request_id)) - wb)
    r.add("offsetof komira_udf_wire_header.flags", Int(UnsafePointer(to=w[].flags)) - wb)
    r.add("offsetof komira_udf_wire_header.slot", Int(UnsafePointer(to=w[].slot)) - wb)
    r.add("offsetof komira_udf_wire_header.payload_offset", Int(UnsafePointer(to=w[].payload_offset)) - wb)
    r.add("offsetof komira_udf_wire_header.payload_len", Int(UnsafePointer(to=w[].payload_len)) - wb)
    free_zeroed(w.bitcast[NoneType]())


def _const_rows(mut r: Rows):
    r.add("const ARROW_FLAG_NULLABLE", Int(ARROW_FLAG_NULLABLE))
    r.add("const ARROW_DEVICE_CPU", Int(ARROW_DEVICE_CPU))
    r.add("const KOMIRA_UDF_ABI_MAJOR", Int(ABI_MAJOR))
    r.add("const KOMIRA_UDF_ABI_MINOR", Int(ABI_MINOR))
    for c in range(STATUS_COUNT):
        r.add("const KOMIRA_UDF_" + status_name(Int32(c)), c)
    r.add("const KOMIRA_UDF_SHAPE_SCALAR", Int(SHAPE_SCALAR))
    r.add("const KOMIRA_UDF_SHAPE_ROW", Int(SHAPE_ROW))
    r.add("const KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN", Int(SHAPE_MAP_BATCHES_COLUMN))
    r.add("const KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME", Int(SHAPE_MAP_BATCHES_FRAME))
    r.add("const KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED", Int(SHAPE_MAP_BATCHES_FRAME_GROUPED))
    r.add("const KOMIRA_UDF_SHAPE_AGG_PLAIN", Int(SHAPE_AGG_PLAIN))
    r.add("const KOMIRA_UDF_SHAPE_AGG_MERGEABLE", Int(SHAPE_AGG_MERGEABLE))
    r.add("const KOMIRA_UDF_SHAPE_STEP", Int(SHAPE_STEP))
    r.add("const KOMIRA_UDF_THREAD_SAFE", Int(THREAD_SAFE))
    r.add("const KOMIRA_UDF_CONTEXT_PER_THREAD", Int(CONTEXT_PER_THREAD))
    r.add("const KOMIRA_UDF_SINGLE_THREAD", Int(SINGLE_THREAD))
    r.add("const KOMIRA_UDF_TRANSPORT_IN_PROCESS", Int(TRANSPORT_IN_PROCESS))
    r.add("const KOMIRA_UDF_TRANSPORT_WORKER", Int(TRANSPORT_WORKER))
    r.add("const KOMIRA_UDF_HOSTING_NONE", Int(HOSTING_NONE))
    r.add("const KOMIRA_UDF_HOSTING_EMBEDDED", Int(HOSTING_EMBEDDED))
    r.add("const KOMIRA_UDF_HOSTING_HOST_INTERPRETER", Int(HOSTING_HOST_INTERPRETER))
    r.add("const KOMIRA_UDF_CLASS_NATIVE", Int(CLASS_NATIVE))
    r.add("const KOMIRA_UDF_CLASS_MANAGED", Int(CLASS_MANAGED))
    r.add("const KOMIRA_UDF_DEVICE_CPU", Int(DEVICE_CPU))
    r.add("const KOMIRA_UDF_FEATURE_MEMORY_REPORT", Int(FEATURE_MEMORY_REPORT))
    r.add("const KOMIRA_UDF_FORM_PACKAGE", Int(FORM_PACKAGE))
    r.add("const KOMIRA_UDF_FORM_BUNDLE", Int(FORM_BUNDLE))
    r.add("const KOMIRA_UDF_FORM_VALUE", Int(FORM_VALUE))
    r.add("const KOMIRA_UDF_NULL_MANUAL", Int(NULL_MANUAL))
    r.add("const KOMIRA_UDF_NULL_PROPAGATE", Int(NULL_PROPAGATE))
    r.add("const KOMIRA_UDF_IMMUTABLE", Int(IMMUTABLE))
    r.add("const KOMIRA_UDF_STABLE", Int(STABLE))
    r.add("const KOMIRA_UDF_VOLATILE", Int(VOLATILE))
    r.add("const KOMIRA_UDF_WIRE_MAGIC", Int(WIRE_MAGIC))
    r.add("const KOMIRA_UDF_WIRE_VERSION", Int(WIRE_VERSION))
    r.add("const KOMIRA_UDF_WIRE_HEADER_BYTES", WIRE_HEADER_BYTES)
    r.add("const KOMIRA_UDF_WIRE_INLINE", Int(WIRE_INLINE))
    r.add("const KOMIRA_UDF_WIRE_END", Int(WIRE_END))
    var names = request_op_names()
    for i in range(len(names)):
        r.add("const KOMIRA_UDF_OP_" + names[i], i + 1)
    r.add("const KOMIRA_UDF_OP_OK", Int(OP_OK))
    r.add("const KOMIRA_UDF_OP_ERROR", Int(OP_ERROR))


def _index(names: List[String], name: String) -> Int:
    for i in range(len(names)):
        if names[i] == name:
            return i
    return -1


def main() raises:
    # The probe answers NULL and -1 just outside its rows (layout_probe.c's
    # bounds checks).
    var edges = c_layout_edges()
    assert_equal(edges[0], 1, "name(-1) is not NULL")
    assert_equal(edges[1], 1, "name(count) is not NULL")
    assert_equal(edges[2], -1, "value(-1)")
    assert_equal(edges[3], -1, "value(count)")
    var c = c_layout_rows()
    var m = Rows()
    _schema_rows(m)
    _array_rows(m)
    _stream_rows(m)
    _udf_rows(m)
    _spec_rows(m)
    _table_rows(m)
    _const_rows(m)
    var bad = List[String]()
    for i in range(len(c.names)):
        var j = _index(m.names, c.names[i])
        if j < 0:
            bad.append(c.names[i] + ": in C only")
        elif m.values[j] != c.values[i]:
            bad.append(c.names[i] + ": C " + String(c.values[i]) + ", Mojo " + String(m.values[j]))
    for j in range(len(m.names)):
        if _index(c.names, m.names[j]) < 0:
            bad.append(m.names[j] + ": in Mojo only")
    var slots = 0
    for i in range(len(c.names)):
        if c.names[i].startswith("slot "):
            slots += 1
    var derived = c.values[_index(c.names, "table_slots")]
    if Int64(slots) != derived:
        bad.append("the probe lists " + String(slots) + " table entries, sizeof gives " + String(derived))
    for i in range(len(bad)):
        print("LAYOUT MISMATCH:", bad[i])
    assert_equal(len(bad), 0, "layout mismatches")
    assert_true(len(c.names) > 150, "the probe reported " + String(len(c.names)) + " rows")
    print("test_layout:", len(c.names), "rows agree")
