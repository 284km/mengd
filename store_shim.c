/* store_shim.c — the two filesystem calls the image store needs and neither
 * the Mere stdlib nor the vendored fs_shim.c has.
 *
 * Kept separate from fs_shim.c on purpose: that file is vendored from mtar and
 * stays byte-identical to its source, so re-vendoring is a copy rather than a
 * merge.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdlib.h>
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

/* ---- running a container ---------------------------------------------- */
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>

/* Fork, point stdout AND stderr at one log file, chdir into the bundle, and
 * exec the runtime. The parent gets the pid back.
 *
 * The two streams go to SEPARATE files, because docker's log protocol tags
 * every frame as stdout (1) or stderr (2) and a single file cannot say which.
 * What is still lost is the interleaving: two files cannot record that a line
 * of stderr came between two lines of stdout. The real daemon multiplexes at
 * the source and keeps it.
 */
/* a3 is optional: an empty string means the argument is not passed at all,
 * rather than passed as "". A runtime that takes an optional pid file must not
 * be handed an empty one and asked to write to it. */
int st_spawn_logged(const char *path, const char *a1, const char *a2, const char *a3,
                    const char *cwd, const char *outfile, const char *errfile) {
    pid_t p = fork();
    if (p < 0) return -1;
    if (p > 0) return (int)p;

    int o = open(outfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int e = open(errfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (o < 0 || e < 0) _exit(125);
    dup2(o, 1); dup2(e, 2);
    if (o > 2) close(o);
    if (e > 2) close(e);
    if (cwd && cwd[0] && chdir(cwd) != 0) _exit(126);
    char *argv[5] = { (char *)path, (char *)a1, (char *)a2, NULL, NULL };
    if (a3 && a3[0]) argv[3] = (char *)a3;
    execv(path, argv);
    _exit(127);
}

/* Blocking wait for one child. The exit status, 128+signal if it was killed. */
int st_wait(int pid) {
    int st = 0;
    if (waitpid((pid_t)pid, &st, 0) < 0) return -1;
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
    return -1;
}

int st_kill(int pid, int sig) { return kill((pid_t)pid, sig) == 0 ? 0 : -1; }

/* A daemon must not die because a client hung up.
 *
 * Writing to a socket the peer has closed raises SIGPIPE, whose default action
 * is to terminate the process. `docker run -d` closes its /wait connection as
 * soon as it has the id, and the very next write killed the whole daemon --
 * exit status 141, which is 128 + SIGPIPE and says so exactly. Ignoring it
 * turns the same event into EPIPE from write(2), which the send loops already
 * treat as "stop writing to this one".
 */
int st_ignore_sigpipe(void) { signal(SIGPIPE, SIG_IGN); return 0; }

/* ---- request buffer slots --------------------------------------------- */
/*
 * The FFI arena is a bump allocator with no free, so one 64 KiB buffer per
 * connection kills the daemon at the 231st request -- measured, and the
 * runtime's own message says what to do instead: reuse the buffers.
 *
 * So there is a fixed pool, acquired and released around each connection. A
 * connection that arrives when every slot is busy waits for one, which is back
 * pressure rather than corruption. Blocking routes hold their slot for as long
 * as they block -- /wait can hold one for minutes -- so the count is also the
 * limit on how many containers can be waited on at once.
 */
#include <pthread.h>
#define MENGD_SLOTS 32
static pthread_mutex_t slot_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  slot_c = PTHREAD_COND_INITIALIZER;
static unsigned char   slot_used[MENGD_SLOTS];

int st_slots(void) { return MENGD_SLOTS; }

int st_slot_acquire(void) {
    pthread_mutex_lock(&slot_m);
    for (;;) {
        for (int i = 0; i < MENGD_SLOTS; i++)
            if (!slot_used[i]) { slot_used[i] = 1; pthread_mutex_unlock(&slot_m); return i; }
        pthread_cond_wait(&slot_c, &slot_m);
    }
}

int st_slot_release(int i) {
    if (i < 0 || i >= MENGD_SLOTS) return -1;
    pthread_mutex_lock(&slot_m);
    slot_used[i] = 0;
    pthread_cond_signal(&slot_c);
    pthread_mutex_unlock(&slot_m);
    return 0;
}

/* ---- timestamps -------------------------------------------------------- */
/*
 * The API's Created fields are RFC 3339 strings, and the client parses them
 * with Go's time package: an empty one is a fatal error, not a missing field.
 * `docker compose up` on a second project died with
 *   parsing time "" as "2006-01-02T15:04:05Z07:00"
 * before it had listed a single network.
 *
 * Formatting a date from epoch seconds is a civil-calendar problem that libc
 * already solves, so it solves it here rather than in the caller.
 */
#include <time.h>
static _Thread_local char ts_buf[64];
const char *st_rfc3339(int secs) {
    time_t t = (time_t)secs;
    struct tm g;
    if (!gmtime_r(&t, &g)) { ts_buf[0] = 0; return ts_buf; }
    strftime(ts_buf, sizeof ts_buf, "%Y-%m-%dT%H:%M:%SZ", &g);
    return ts_buf;
}

/* ---- the host-side proxy ----------------------------------------------- */
/*
 * A connection is handed to a child process by making it the child's stdin and
 * stdout, and the child is `ssh ... socat`. Nothing copies bytes in user space
 * on this side: the kernel already moves them between the socket and the pipe,
 * and a proxy that read and re-wrote every byte would be a second place for
 * the framing to be wrong.
 */
// Per-thread, because the agent forwards a socket and several ports at once
// and a single shared argv would have two threads building one command.
#define PX_MAXV 64
static _Thread_local char *PXV[PX_MAXV + 1];
static _Thread_local int PXn = 0;

int st_px_reset(void) { for (int i = 0; i < PXn; i++) free(PXV[i]); PXn = 0; PXV[0] = NULL; return 0; }
int st_px_push(const char *s) {
    if (PXn >= PX_MAXV) return -1;
    PXV[PXn] = strdup(s);
    if (!PXV[PXn]) return -1;
    PXV[++PXn] = NULL;
    return 0;
}

/* Fork, make `fd` the child's stdin and stdout, exec the pushed argv.
 * Returns the child's pid. */
/* The argv built with st_px_push, spawned detached, with its output appended
 * to a file. Separate from st_px_spawn because that one hands the child a
 * socket as its stdin and stdout, which is right for a proxy and wrong for
 * anything that outlives the request that started it. */
int st_px_spawn_log(const char *errfile) {
    if (PXn == 0) return -1;
    pid_t p = fork();
    if (p < 0) return -1;
    if (p > 0) return (int)p;
    setsid();
    int z = open("/dev/null", O_RDONLY);
    if (z >= 0) { dup2(z, 0); if (z > 2) close(z); }
    int e = open(errfile, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (e >= 0) { dup2(e, 1); dup2(e, 2); if (e > 2) close(e); }
    execvp(PXV[0], PXV);
    _exit(127);
}

int st_px_spawn(int fd) {
    if (PXn == 0) return -1;
    pid_t p = fork();
    if (p < 0) return -1;
    if (p > 0) return (int)p;
    dup2(fd, 0); dup2(fd, 1);
    if (fd > 2) close(fd);
    execvp(PXV[0], PXV);
    _exit(127);
}

/* Reap anything that has finished, without blocking. A proxy that never reaps
 * accumulates zombies at one per connection. */
int st_reap(void) { int n = 0; while (waitpid(-1, NULL, WNOHANG) > 0) n++; return n; }

/* SHA-256 of a file.
 *
 * The runtime's sha256_hex takes a NUL-terminated str, which a layer tarball
 * is not: the digest of an image's contents cannot go through a type that
 * stops at the first zero byte. OpenSSL is already linked here -- declaring
 * the TLS primitives is what does that -- so this is the digest and not a
 * second implementation of one.
 */
#include <openssl/evp.h>

const char *st_sha256_file(const char *path) {
    static _Thread_local char hex[65];
    hex[0] = 0;
    FILE *f = fopen(path, "rb");
    if (!f) return hex;
    EVP_MD_CTX *c = EVP_MD_CTX_new();
    if (!c || EVP_DigestInit_ex(c, EVP_sha256(), NULL) != 1) {
        if (c) EVP_MD_CTX_free(c);
        fclose(f);
        return hex;
    }
    unsigned char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) EVP_DigestUpdate(c, buf, n);
    fclose(f);
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int len = 0;
    EVP_DigestFinal_ex(c, out, &len);
    EVP_MD_CTX_free(c);
    for (unsigned int i = 0; i < len && i < 32; i++) snprintf(hex + i * 2, 3, "%02x", out[i]);
    hex[64] = 0;
    return hex;
}

/* ---- overlay mounts ------------------------------------------------------
 *
 * A build step's layer is the difference between the filesystem before and
 * after it ran, and the kernel will compute that difference exactly if the
 * step runs on an overlay: the upper directory holds what changed and nothing
 * else. Without it the only honest thing a build can write is the whole root
 * filesystem as one layer, which is what this daemon did.
 *
 * redirect_dir=off and metacopy=off because both of them let the upper
 * directory describe a change by REFERENCE to the lower one -- a renamed
 * directory as an xattr pointing at its old path, a chmod as a header with no
 * data. Neither survives being written out as a tar: the layer would be
 * correct only while the overlay it came from still existed.
 */
#ifdef __linux__
#include <sys/mount.h>
int st_mount_overlay(const char *target, const char *opts) {
    char full[8192];
    if (snprintf(full, sizeof full, "%s,redirect_dir=off,metacopy=off", opts) >= (int)sizeof full) return -1;
    return mount("overlay", target, "overlay", 0, full) == 0 ? 0 : -1;
}
/* MNT_DETACH as the second try: a step that left a process behind holds the
 * mount, and a layer read through a mount that is still live is a layer of
 * whatever that process does next. */
int st_umount(const char *target) {
    if (umount(target) == 0) return 0;
    return umount2(target, MNT_DETACH) == 0 ? 0 : -1;
}
#else
/* No overlayfs. The caller says so in the build output and writes one layer;
 * it does not pretend the mount happened. */
int st_mount_overlay(const char *target, const char *opts) { (void)target; (void)opts; return -1; }
int st_umount(const char *target) { (void)target; return -1; }
#endif

/* mkdir that FAILS when the directory is already there.
 *
 * mkdir_p answers the same whether it made the directory or found it, which is
 * what a path wants and the opposite of what a claim wants. This daemon serves
 * a thread per connection, and compose starts its services at the same time:
 * two threads reading the addresses in use and each picking "the next one"
 * both picked the same one, and two containers came up on 10.88.1.2.
 *
 * mkdir is atomic, so the directory IS the lease. */
int st_mkdir_excl(const char *path) { return mkdir(path, 0755) == 0 ? 0 : -1; }
