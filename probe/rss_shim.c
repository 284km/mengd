/* probe/rss_shim.c — this process's resident size, from the kernel.
 *
 * Linux only, because /proc is where the number is and the question is about
 * a daemon that runs on Linux. */
#include <stdio.h>
int rss_kb(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    int kb = -1;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "VmRSS: %d kB", &kb) == 1) break;
    fclose(f);
    return kb;
}
