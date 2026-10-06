/* The program kcov_check.sh runs under the built kcov, with no arguments.
 * A line marked COV:hit must be reported with hits >= 1, a COV:miss line
 * with hits 0, and the report must be cov_fixture.cobertura.xml: an edit
 * that moves a line changes that golden too. */
#include <stdio.h>

static int covered(int x)
{
	return x + 1; /* COV:hit */
}

static int uncovered(int x)
{
	return x * 2; /* COV:miss */
}

int main(int argc, char **argv)
{
	int r = covered(argc); /* COV:hit */

	(void)argv;
	if (argc > 5) {
		r = uncovered(r); /* COV:miss */
	}
	printf("cov_fixture %d\n", r); /* COV:hit */
	return 0;
}
