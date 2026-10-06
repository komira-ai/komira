/* The three libcurl functions kcov's utils.cc calls (escape_url, used by the
 * HTML writer), declared for a build with no libcurl. curl_shim.c defines
 * them. kcov's Coveralls upload, the only other curl user, is replaced by its
 * own dummy-coveralls-writer.cc in this build. */
#ifndef KOMIRA_KCOV_CURL_SHIM_H
#define KOMIRA_KCOV_CURL_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void CURL;

CURL *curl_easy_init(void);
char *curl_easy_escape(CURL *handle, const char *string, int length);
void curl_easy_cleanup(CURL *handle);

#ifdef __cplusplus
}
#endif

#endif
