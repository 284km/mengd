/* store_shim.c — the two filesystem calls the image store needs and neither
 * the Mere stdlib nor the vendored fs_shim.c has.
 *
 * Kept separate from fs_shim.c on purpose: that file is vendored from mtar and
 * stays byte-identical to its source, so re-vendoring is a copy rather than a
 * merge.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

int st_rename(const char *from, const char *to) { return rename(from, to) == 0 ? 0 : -1; }

/* Recursive delete. Needed because an image that turns out to be already
 * loaded has by then been unpacked: the manifest naming it is inside the
 * archive, so there is nothing to compare against until after unpacking. A
 * duplicate `docker load` was leaving the whole extracted tree behind --
 * 7.9 MB for alpine, every time.
 *
 * lstat, and never following a symlink: the tree being deleted came out of an
 * untrusted archive, and a symlink to / would otherwise be walked into.
 */
static int rmtree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(st.st_mode)) return unlink(path) == 0 ? 0 : -1;

    DIR *d = opendir(path);
    if (!d) return -1;
    struct dirent *e;
    int rc = 0;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char child[4096];
        if (snprintf(child, sizeof child, "%s/%s", path, e->d_name) >= (int)sizeof child) { rc = -1; continue; }
        if (rmtree(child) != 0) rc = -1;
    }
    closedir(d);
    if (rc != 0) return -1;
    return rmdir(path) == 0 ? 0 : -1;
}
int st_rmtree(const char *path) { return rmtree(path); }
