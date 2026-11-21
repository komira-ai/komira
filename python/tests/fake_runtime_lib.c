// A stand-in for a Mojo runtime library, for the runtime check's tests
// (test_runtime.py): one exported integer, FAKE_MARKER. Each target builds it
// with its own SONAME and GNU build id (link flags in tests/BUCK), so a test
// can load a copy by path and ask for it by SONAME.

#define EXPORT __attribute__((visibility("default")))

EXPORT int fake_runtime_marker = FAKE_MARKER;
