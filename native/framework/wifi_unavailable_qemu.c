#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static int should_skip_wifi_sa(void)
{
    char s[96] = {0};
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, s, sizeof(s) - 1);
    close(fd);
    if (n <= 0) return 0;
    return strcmp(s, "com.ohos.sceneboard") == 0 ||
           strcmp(s, "softbus_server") == 0 ||
           strcmp(s, "device_manager") == 0 ||
           strstr(s, "softbus_server") != NULL ||
           strstr(s, "device_manager") != NULL;
}

int wifi_load(void *self, int id) __asm__("_ZN4OHOS4Wifi17WifiSaLoadManager10LoadWifiSaEi");
int wifi_load(void *self, int id)
{
    if (id >= 1120 && id <= 1125 && should_skip_wifi_sa()) return 1;
    typedef int (*next_fn)(void *, int);
    next_fn next = (next_fn)dlsym(RTLD_NEXT, "_ZN4OHOS4Wifi17WifiSaLoadManager10LoadWifiSaEi");
    return next ? next(self, id) : 1;
}
