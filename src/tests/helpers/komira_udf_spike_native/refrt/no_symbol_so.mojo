# The one export of the no_symbol shared library: a function that is not
# komira_udf_native_init_v1, so the native runtime must refuse the library
# as one without the native library symbol. No pointer crosses it.


@export
def komira_udf_spike_no_symbol() abi("C") -> Int32:
    return 7
