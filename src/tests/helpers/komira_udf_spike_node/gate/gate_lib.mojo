# =============================================================================
# FFI-BOUNDARY: the export of load_gate.so, the Mojo library the load gate
# (tests/load_gate.js) loads into node.
# =============================================================================
# komira_udf_spike_node_load_gate(n) takes and returns integers only: no
# pointer crosses. It uses the Mojo runtime the library starts in the host
# process (its allocator, through a List and a String), so a library whose
# runtime cannot start there fails the call.
# =============================================================================


@export
def komira_udf_spike_node_load_gate(n: Int64) abi("C") -> Int64:
    """The sum of i * i for i < n, through a heap List and a String."""
    var xs = List[Int64]()
    for i in range(Int(n)):
        xs.append(Int64(i) * Int64(i))
    var text = String("")
    var total: Int64 = 0
    for x in xs:
        total += x
        text += "."
    return total if text.byte_length() == Int(n) else -1
