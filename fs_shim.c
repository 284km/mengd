/* fs_shim.c — the filesystem calls tar needs and the Mere stdlib does not have.
 *
 * Mere has mkdir_p / write_bytes / file_pread_bytes, but no symlink, no
 * hardlink and no chmod. Those three are what a tar extractor cannot fake:
 * the measured corpus (see test/CORPUS) is 45% symlinks by entry count.
 *
 * Everything crosses as C `int` / `const char *`, the shape the socket family
 * already uses.
 */
#include <sys/stat.h>
#include <unistd.h>

int fs_symlink(const char *target, const char *path) { return symlink(target, path) == 0 ? 0 : -1; }
int fs_link(const char *target, const char *path)    { return link(target, path) == 0 ? 0 : -1; }
int fs_chmod(const char *path, int mode)             { return chmod(path, (mode_t)mode) == 0 ? 0 : -1; }
int fs_unlink(const char *path)                      { return unlink(path) == 0 ? 0 : -1; }

/* Set the mode of a symlink WITHOUT following it. bsdtar applies the archive's
 * mode here (0777 for every symlink in the corpus); plain chmod() would follow
 * the link and change the target instead.
 *
 * Returns 0 applied, 1 not applicable on this platform, -1 failed. Linux has
 * no lchmod and symlink modes there are fixed at 0777, so it reports 1 rather
 * than claiming a write it did not make.
 */
int fs_lchmod(const char *path, int mode) {
#if defined(__APPLE__)
    return lchmod(path, (mode_t)mode) == 0 ? 0 : -1;
#else
    (void)path; (void)mode; return 1;
#endif
}

/* Restore ownership without following symlinks.
 *
 * tar only does this when it can: as a non-root user every call fails with
 * EPERM, and that is not an error in the archive. Returns 0 applied,
 * 1 not permitted (skipped, the non-root case), -1 a real failure. P1 runs as
 * root inside the guest, where this is the difference between a correct
 * rootfs and one where every file belongs to the extracting user.
 */
#include <errno.h>
int fs_lchown(const char *path, int uid, int gid) {
    if (lchown(path, (uid_t)uid, (gid_t)gid) == 0) return 0;
    return errno == EPERM ? 1 : -1;
}

/* Is this path itself a symlink? 1 yes, 0 no (including "does not exist").
 *
 * This is the one question the name of an entry cannot answer. An archive may
 * legitimately contain `bin/sh -> /bin/busybox` (1,706 such links in the test
 * corpus), and the danger is not the link but a LATER entry named `bin/foo`
 * whose ancestor `bin` is a symlink -- the write lands wherever the link
 * points. lstat, not stat: stat would follow the very link being asked about.
 */
#include <sys/types.h>
int fs_is_symlink(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    return S_ISLNK(st.st_mode) ? 1 : 0;
}
