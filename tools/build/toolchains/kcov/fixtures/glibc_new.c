/* A program that needs a glibc newer than the floor: arc4random is
 * GLIBC_2.36. kcov_check.sh `cases` links it for glibc 2.38, where its
 * glibc-floor check must name GLIBC_2.36, and for the floor, where the link
 * must fail. */
#define _DEFAULT_SOURCE
#include <stdlib.h>

int main(void)
{
	return (int)(arc4random() & 1);
}
