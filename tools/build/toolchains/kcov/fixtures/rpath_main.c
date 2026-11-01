/* The probe kcov_check `cases` links against libkcovprobe.so.1 with the
 * run path $ORIGIN/../lib, as kcov_build links bin/kcov against
 * libgcc_s.so.1: it prints `kcov_probe 42` when the loader took its own
 * library. */
#include <stdio.h>

int kcov_probe(void);

int main(void)
{
	printf("kcov_probe %d\n", kcov_probe());
	return 0;
}
