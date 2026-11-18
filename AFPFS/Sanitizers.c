// fskit extensions' stderr goes to /dev/null, so this file sets up the sanitizer options
// to additionally log to the syslog and to the /tmp in our container

#if defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer)
#include <stdlib.h>

__attribute__((disable_sanitizer_instrumentation))
static const char *sanitizerOptions(const char *name)
{
    static char options[1024];
    const char *home = getenv("HOME");
    const char *parts[] = { "symbolize=0:log_to_syslog=1:log_path=", home ?: "",
                            "/Library/Containers/com.benjaminlowry.AFPConnect.AFPFS/Data/tmp/", name };
    size_t n = 0;
    for (size_t i = 0; i < sizeof(parts) / sizeof(parts[0]); i++) {
        for (const char *c = parts[i]; *c && n < sizeof(options) - 1; c++) {
            options[n++] = *c;
        }
    }
    options[n] = '\0';
    return options;
}
#endif
#if __has_feature(address_sanitizer)
const char *__asan_default_options(void);
__attribute__((disable_sanitizer_instrumentation))
const char *__asan_default_options(void)
{
    return sanitizerOptions("asan");
}
#endif
#if __has_feature(thread_sanitizer)
const char *__tsan_default_options(void);
__attribute__((disable_sanitizer_instrumentation))
const char *__tsan_default_options(void)
{
    return sanitizerOptions("tsan");
}
#endif
#endif
