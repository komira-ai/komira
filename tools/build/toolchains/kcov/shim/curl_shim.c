/* SPDX-License-Identifier: MIT
 *
 * This file is MIT-licensed, not Apache-2.0 like the rest of the repository:
 * it is compiled into the GPL-2.0 kcov binary, and Apache-2.0 code cannot be
 * combined into a GPL-2.0 program. See README.md, Licences. */
/* curl_easy_escape and friends without libcurl (see curl/curl.h).
 *
 * curl_easy_escape percent-encodes every byte that is not an RFC 3986
 * unreserved character (A-Z a-z 0-9 - . _ ~), as libcurl does; a length of 0
 * means strlen(string). The result is malloc'd: kcov releases it with free().
 * Returns NULL when out of memory, which kcov treats as "keep the input". */
#include <stdlib.h>
#include <string.h>

#include "curl/curl.h"

static int unreserved(unsigned char c)
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
	       c == '-' || c == '.' || c == '_' || c == '~';
}

CURL *curl_easy_init(void)
{
	static char handle;
	return &handle;
}

char *curl_easy_escape(CURL *handle, const char *string, int length)
{
	static const char hex[] = "0123456789ABCDEF";
	size_t n = length > 0 ? (size_t)length : strlen(string);
	char *out = malloc(3 * n + 1);
	size_t j = 0;

	(void)handle;
	if (!out)
		return NULL;
	for (size_t i = 0; i < n; i++) {
		unsigned char c = (unsigned char)string[i];
		if (unreserved(c)) {
			out[j++] = (char)c;
		} else {
			out[j++] = '%';
			out[j++] = hex[c >> 4];
			out[j++] = hex[c & 15];
		}
	}
	out[j] = '\0';
	return out;
}

void curl_easy_cleanup(CURL *handle)
{
	(void)handle;
}
