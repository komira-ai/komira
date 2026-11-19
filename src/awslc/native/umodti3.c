// __umodti3, the unsigned 128-bit remainder the compiler emits for a
// `uint128_t % uint128_t` (libcrypto's BN_mod_word does one).
//
// The C toolchain's only other definition is in zig's compiler_rt, in one
// object that also defines weak memset, expf, floorf and some seventy other
// libc and libm functions. Pulling that object into an executable would
// export those definitions (the Mojo runtime library references them) and
// take over the runtime's calls from glibc. This one is hidden, as is all of
// libcrypto, and pulls in nothing.
//
// Bit-serial long division, using only shifts, compares and subtraction,
// which x86_64 does inline for 128-bit operands.

__attribute__((visibility("hidden"))) unsigned __int128 __umodti3(unsigned __int128 a, unsigned __int128 b) {
    if (b == 0) {
        __builtin_trap();
    }
    unsigned __int128 r = 0;
    for (int i = 127; i >= 0; i--) {
        // r < b, so r * 2 + 1 < 2 * b: one subtraction brings it below b,
        // including when r * 2 overflows 128 bits (top set).
        unsigned __int128 top = r >> 127;
        r = (r << 1) | ((a >> i) & 1);
        if (top || r >= b) {
            r -= b;
        }
    }
    return r;
}
