"""The engine's host of UDF runtimes (docs/design/udf_runtime_interface.md
section 4): `UdfRuntime` (one runtime library opened with its options),
`UdfBinding` (the UDFs of one plan, admitted and loaded) and `UdfInstance`
(one worker's calls of one UDF, with the host's null propagation and
post-conditions). See README.md."""
