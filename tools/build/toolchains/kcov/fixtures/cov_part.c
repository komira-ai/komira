/* The second source of the fixture of kcov_check.sh check 8, linked with
 * cov_fixture.c: two files in one directory, so kcov's Cobertura writer
 * would name each relative to that directory unless it writes full paths.
 * The constructor runs before main and prints nothing. A line marked
 * COV:hit must be reported with hits >= 1, a COV:miss line with hits 0, and
 * the report must be cov_fixture_relocated.cobertura.xml. */
static volatile int cov_part_value;

static int cov_part_twice(int x)
{
	return x * 2; /* COV:miss */
}

__attribute__((constructor)) static void cov_part_init(void)
{
	cov_part_value = 1; /* COV:hit */
	if (cov_part_value > 1) {
		cov_part_value = cov_part_twice(cov_part_value); /* COV:miss */
	}
}
