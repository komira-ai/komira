# The Mojo side of the one-definition gate (BUCK): one C-ABI function, so the
# shared library the gate links has an entry of its own besides the C
# libraries it links whole-archive.


@export
def komira_one_definition_gate() abi("C") -> Int32:
    return 0
