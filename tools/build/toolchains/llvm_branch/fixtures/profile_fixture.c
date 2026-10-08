/* The program the raw-version check instruments (check.sh raw_version).
 *
 * Compiled to LLVM bitcode by zig cc, instrumented by Mojo's lld with the
 * passes a coverage build uses, linked with the pinned profile runtime and
 * run. Three functions, so `llvm-profdata show` must report
 * `Total functions: 3`. classify is entered 5 times and its branch is
 * taken for 3 and 4 only, so its two counters are 2 and 3 (the order is the
 * instrumentation's), total(5) is 2 and the program exits 0. noinline keeps
 * each function a function of its own. */

__attribute__((noinline)) static int classify(int x) {
    if (x > 2) return 1;
    return 0;
}

__attribute__((noinline)) static int total(int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += classify(i);
    return s;
}

int main(void) { return total(5) == 2 ? 0 : 1; }
