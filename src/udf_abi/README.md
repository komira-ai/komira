# udf_abi

The C ABI of a UDF runtime, version 1.0: `komira_udf_runtime.h`. It holds the runtime table
(`komira_udf_runtime`), the host struct the engine passes to `init` (`komira_udf_host`), the
capabilities, the spec and call structs, the statuses, and the Arrow C Data, C Stream and C Device
structs it embeds, so a runtime needs no Arrow header. The design is
[`docs/design/udf_runtime_interface.md`](../../docs/design/udf_runtime_interface.md) section 4.3.

Every struct that crosses the ABI begins with `size_t struct_size`; within the major version, fields
and entries are only appended. The latest appended fields are `n_options` and `options` at the end of
`komira_udf_host` (runtime options as `key=value` strings, opaque to the engine) and the status
`KOMIRA_UDF_ERR_BAD_OPTION` (21), which `init` returns for an option it refuses. A runtime reads the
options only when `host->struct_size` covers them.

The header is the only file here. `//src/udf_abi:komira_udf_runtime.h` is the file and
`//src/udf_abi:headers` a filegroup of it, for a C library's include directories.

The worker message header (`komira_udf_wire.h`), the Mojo mirror and the conformance harness are
still in [`src/tests/helpers/komira_udf_spike_abi`](../tests/helpers/komira_udf_spike_abi/).
