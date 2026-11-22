/* The first member of the archives the cases of prefix_tool read
 * (README.md): one symbol of each kind the reader tells apart. */
extern int fx_undefined(int);
extern int fx_weak_hook(int) __attribute__((weak));

int fx_common_data;
int fx_data = 1;

static int fx_local(int x) { return x + 1; }

__attribute__((visibility("hidden"))) int fx_hidden(int x) { return fx_local(x) + fx_data; }

__attribute__((weak)) int fx_weak_def(int x) { return x; }

int fx_global(int x) { return fx_undefined(x) + (fx_weak_hook ? fx_weak_hook(x) : 0) + fx_hidden(x); }
