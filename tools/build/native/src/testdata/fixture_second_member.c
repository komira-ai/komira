/* The second member of the archives the cases of prefix_tool read
 * (README.md): a name longer than an ar header holds, and a reference to
 * a name the first member defines. */
extern int fx_global(int);

int fx_second(int x) { return fx_global(x) * 2; }
