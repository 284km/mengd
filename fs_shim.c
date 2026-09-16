/* Vendored from 284km/mtar fs_shim.c by tools/vendor-mgz.sh. Do not edit here. */
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
#include <dirent.h>
int fs_is_symlink(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    return S_ISLNK(st.st_mode) ? 1 : 0;
}

/* ---- a refusal that a library can survive ------------------------------ */
/*
 * The reader used to refuse by printing and calling exit(3). That is right for
 * a CLI and a denial of service inside anything long-lived: mengd vendors this
 * reader and serves `docker load`, so any client that uploaded a malformed
 * archive took the whole daemon down.
 *
 * So a refusal is now RECORDED and the walk unwinds with -1. The CLI reads the
 * message back and exits 3 itself, which keeps its behaviour identical; a
 * library caller checks the return value and stays alive.
 *
 * One slot per thread: two concurrent extractions must not overwrite each
 * other's reason, and mengd extracts concurrently.
 */
#include <stdio.h>
#include <string.h>
static _Thread_local char fs_err[512];

int fs_fail(const char *what, const char *ctx) {
    snprintf(fs_err, sizeof fs_err, "%s  [%s]", what ? what : "", ctx ? ctx : "");
    return -1;
}
const char *fs_last_error(void) { return fs_err; }
int fs_clear_error(void) { fs_err[0] = 0; return 0; }
int fs_has_error(void) { return fs_err[0] != 0 ? 1 : 0; }

/* ---- reading a tree, for the writer ------------------------------------- */
/*
 * Everything below exists because an archive has to be BUILT from a directory,
 * and neither the language nor this shim could look at one: no directory
 * listing, no lstat, no readlink.
 */
#define FS_DIRS 32
static DIR *FS_DIR[FS_DIRS];

int fs_opendir(const char *path) {
    for (int i = 0; i < FS_DIRS; i++) {
        if (FS_DIR[i]) continue;
        DIR *d = opendir(path);
        if (!d) return -1;
        FS_DIR[i] = d;
        return i;
    }
    return -2;                      /* no room: a refusal, not "empty" */
}

/* The next name, or "" at the end. "." and ".." are never returned: a walker
 * that had to skip them is a walker that can forget to. */
static _Thread_local char FS_NAME[1024];
const char *fs_readdir(int h) {
    FS_NAME[0] = 0;
    if (h < 0 || h >= FS_DIRS || !FS_DIR[h]) return FS_NAME;
    struct dirent *e;
    while ((e = readdir(FS_DIR[h]))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(FS_NAME, sizeof FS_NAME, "%s", e->d_name);
        return FS_NAME;
    }
    return FS_NAME;
}

int fs_closedir(int h) {
    if (h < 0 || h >= FS_DIRS || !FS_DIR[h]) return -1;
    closedir(FS_DIR[h]);
    FS_DIR[h] = NULL;
    return 0;
}

/*
 * lstat once, then ask about it. One call per field because a tuple cannot
 * cross the FFI boundary -- and the stat is CACHED rather than repeated,
 * because five questions about one file should not be five system calls, and a
 * file that changed between them would be answering five questions about five
 * different files.
 */
static _Thread_local struct stat FS_ST;
static _Thread_local int FS_ST_OK;

int fs_lstat(const char *path) {
    FS_ST_OK = (lstat(path, &FS_ST) == 0);
    return FS_ST_OK ? 0 : -1;
}
int fs_st_mode(void)  { return FS_ST_OK ? (int)(FS_ST.st_mode & 07777) : -1; }
int fs_st_mtime(void) { return FS_ST_OK ? (int)FS_ST.st_mtime : -1; }
int fs_st_uid(void)   { return FS_ST_OK ? (int)FS_ST.st_uid : -1; }
int fs_st_gid(void)   { return FS_ST_OK ? (int)FS_ST.st_gid : -1; }
/* 0 file, 1 directory, 2 symlink, 3 something else -- which the caller refuses
 * by name rather than guessing a type flag for. */
int fs_st_kind(void) {
    if (!FS_ST_OK) return -1;
    if (S_ISREG(FS_ST.st_mode)) return 0;
    if (S_ISDIR(FS_ST.st_mode)) return 1;
    if (S_ISLNK(FS_ST.st_mode)) return 2;
    return 3;
}
/* -1 for a size this boundary cannot carry. The FFI int is 32 bits, and a
 * silently truncated size writes a header that says one length and a body that
 * is another -- which every reader would believe. */
int fs_st_size(void) {
    if (!FS_ST_OK) return -1;
    if (FS_ST.st_size > 2147483647LL) return -1;
    return (int)FS_ST.st_size;
}

static _Thread_local char FS_LINK[1024];
const char *fs_readlink(const char *path) {
    ssize_t n = readlink(path, FS_LINK, sizeof FS_LINK - 1);
    FS_LINK[n > 0 ? n : 0] = 0;
    return FS_LINK;
}

/* Remove a path and everything under it, for the whiteout rule: a layer entry
 * named .wh.x deletes x from every layer below, and x may be a whole subtree.
 *
 * Written out with opendir/readdir rather than nftw: glibc puts nftw behind a
 * feature-test macro, so the version that compiled here refused to compile on
 * the Linux image -- and defining the macro would have changed what every
 * other declaration in this file means.
 *
 * Symlinks are unlinked, never followed: following one would delete outside
 * the destination, which is the escape the extractor's R3 rule refuses.
 * Missing is not a failure -- a whiteout for something no lower layer had is a
 * no-op, and builders emit those. */
int fs_rmtree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    if (!S_ISDIR(st.st_mode)) return unlink(path) == 0 ? 0 : -1;
    DIR *d = opendir(path);
    if (!d) return -1;
    struct dirent *e;
    int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char child[4096];
        if (snprintf(child, sizeof child, "%s/%s", path, e->d_name) >= (int)sizeof child) { rc = -1; continue; }
        if (fs_rmtree(child) != 0) rc = -1;
    }
    closedir(d);
    if (rc != 0) return rc;
    return rmdir(path) == 0 ? 0 : -1;
}

/* Everything in a directory, but not the directory. The opaque whiteout
 * (.wh..wh..opq) says "the layers below contributed nothing here". */
int fs_empty_dir(const char *path) {
    DIR *d = opendir(path);
    if (!d) return 0;
    struct dirent *e;
    int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char child[4096];
        if (snprintf(child, sizeof child, "%s/%s", path, e->d_name) >= (int)sizeof child) { rc = -1; continue; }
        if (fs_rmtree(child) != 0) rc = -1;
    }
    closedir(d);
    return rc;
}
