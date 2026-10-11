# Which libraries import inside a runtime's contexts: one probe UDF per
# library (pyrt/probe_<lib>.py imports it at the top), opened as an instance
# in one context and then in a second one, so the outcome of the first
# import and of an import after it are both recorded. Shared by the import tests of each
# runtime build (tests/test_imports_*.mojo), which pin the outcomes.

from komira_udf_spike_abi.contract import OK, SHAPE_SCALAR, status_name
from komira_udf_spike_abi.runtime import UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import ColumnType, TYPE_INT64


def probe_libraries() -> List[String]:
    return ["numpy", "pandas", "pyarrow", "sklearn", "cloudpickle"]


@fieldwise_init
struct ImportOutcome(Copyable, Movable, Writable):
    var library: String
    var context: Int
    var status: Int32
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.library, " context ", self.context, ": ", status_name(self.status))
        if self.message != "":
            writer.write(" '", self.message, "'")


def import_outcomes(mut rt: UdfRuntime) raises -> List[ImportOutcome]:
    """For each library, the status of open_instance of its probe in context
    0, then (that context closed) in context 1: a second import in a new
    context, after the first one's interpreter is gone."""
    var out = List[ImportOutcome]()
    for lib in probe_libraries():
        var spec = UdfSpec(
            SHAPE_SCALAR, "probe_" + lib + ":probe", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT64, True)]
        )
        var u = rt.load(spec)
        if not u.outcome.is_ok():
            raise Error("load probe_" + lib + ": " + String(u.outcome))
        for slot in range(2):
            var c = rt.open_context(UInt32(slot))
            if not c.outcome.is_ok():
                raise Error("open_context: " + String(c.outcome))
            var i = rt.open_instance(c.handle, u.handle)
            out.append(ImportOutcome(lib, slot, i.outcome.status, i.outcome.message))
            if i.outcome.status == OK:
                rt.close_instance(i.handle)
            rt.close_context(c.handle)
        rt.unload(u.handle)
    return out^
