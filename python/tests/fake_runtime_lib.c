// A stand-in for a Mojo runtime library, for the runtime check's tests
// (test_runtime.py): one exported integer, FAKE_MARKER. Each target builds it
// with its own SONAME (a link flag in tests/BUCK) and, with FAKE_BUILD_ID set
// (four comma-separated bytes), a GNU build id note of those bytes, written
// here rather than by the linker (which links with --build-id=none), so the
// note holds exactly the bytes the test expects. Without FAKE_BUILD_ID the
// library has no build id.

#define EXPORT __attribute__((visibility("default")))

#define FAKE_STR2(...) #__VA_ARGS__
#define FAKE_STR(...) FAKE_STR2(__VA_ARGS__)

#ifdef FAKE_BUILD_ID
// Owner "GNU" (namesz 4), a 4-byte descriptor, type NT_GNU_BUILD_ID (3), in
// an allocated SHT_NOTE section, which the linker keeps and puts in a PT_NOTE
// segment. Not named `.note.gnu.build-id`: the linker owns that name.
__asm__(".section .note.komira.fake-build-id,\"a\",@note\n"
        ".balign 4\n"
        ".long 4\n"
        ".long 4\n"
        ".long 3\n"
        ".asciz \"GNU\"\n"
        ".byte " FAKE_STR(FAKE_BUILD_ID) "\n"
        ".previous\n");
#endif

EXPORT int fake_runtime_marker = FAKE_MARKER;
