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
#include <stdint.h>

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

/* base64, for the one header the archive routes have to send.
 *
 * `docker cp` decides whether it is copying a file or a directory from
 * X-Docker-Container-Path-Stat, which is base64 of a small JSON object. It is
 * 30 lines here and a dependency anywhere else. */
int st_b64(const char *in, char *out, int outcap) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t n = strlen(in);
    size_t need = 4 * ((n + 2) / 3) + 1;
    if ((int)need > outcap) return -1;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        unsigned v = (unsigned char)in[i] << 16;
        if (i + 1 < n) v |= (unsigned char)in[i + 1] << 8;
        if (i + 2 < n) v |= (unsigned char)in[i + 2];
        out[o++] = T[(v >> 18) & 63];
        out[o++] = T[(v >> 12) & 63];
        out[o++] = i + 1 < n ? T[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < n ? T[v & 63] : '=';
    }
    out[o] = 0;
    return (int)o;
}
static _Thread_local char ST_B64[8192];
const char *st_b64_of(const char *in) {
    if (st_b64(in, ST_B64, (int)sizeof ST_B64) < 0) { ST_B64[0] = 0; }
    return ST_B64;
}

/* ---- docker exec ----------------------------------------------------------
 *
 * A second process inside a container that is already running. The namespaces
 * are named by the container's pid, and entering them is what makes the
 * process BE inside: the mount namespace gives it the container's filesystem,
 * the pid namespace makes it a child of the container's init, the network one
 * gives it the container's address.
 *
 * The argv arrives in a FILE, one argument per line. The FFI boundary carries
 * `int` and `const char *`, so a list of unknown length cannot cross it -- and
 * padding it out to a fixed number of slots is how a command with five
 * arguments silently becomes one with four.
 *
 * ORDER MATTERS TWICE. The output files are opened BEFORE entering the mount
 * namespace, because afterwards those paths mean something else entirely. And
 * the pid namespace only takes effect for a CHILD, so there is a second fork
 * after setns -- without it the process runs in the container's filesystem
 * while still being outside its process table.
 */
#ifdef __linux__
#include <sched.h>
static int ex_enter(int pid, const char *what) {
    char p[256];
    snprintf(p, sizeof p, "/proc/%d/ns/%s", pid, what);
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int rc = setns(fd, 0);
    close(fd);
    return rc;
}
#else
static int ex_enter(int pid, const char *what) { (void)pid; (void)what; return -1; }
#endif

static char **ex_read_argv(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    char **v = calloc(64, sizeof *v);
    if (!v) { fclose(f); return NULL; }
    int n = 0;
    char line[4096];
    while (n < 62 && fgets(line, sizeof line, f)) {
        size_t l = strlen(line);
        while (l > 0 && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        v[n++] = strdup(line);
    }
    fclose(f);
    v[n] = NULL;
    return n > 0 ? v : (free(v), NULL);
}

/* ---- stdin for an exec ----------------------------------------------------
 *
 * `docker exec -i` sends the command's standard input as RAW BYTES on the
 * upgraded connection, after the 101. Without somewhere to put them the daemon
 * finished, closed the socket, and the client -- still writing -- got
 * "connection reset by peer".
 *
 * So the child's stdin is a pipe, and the caller gets its write end. TWO
 * VALUES OUT OF ONE CALL is the awkward part, and the answer is the one this
 * project already uses for exactly this: the pid goes in a FILE, the way mrun
 * writes the container's pid, and the return value is the fd. Hiding one of
 * them in a static would work until two execs ran at once.
 */
int ex_spawn_in(int cpid, const char *argvfile, const char *envfile,
                const char *cwd, const char *outfile, const char *errfile,
                const char *pidfile);

/* Returns the child's pid, or -1. The caller waits for it with st_wait. */
int ex_spawn(int cpid, const char *argvfile, const char *envfile,
             const char *cwd, const char *outfile, const char *errfile) {
    char **argv = ex_read_argv(argvfile);
    if (!argv) return -1;
    char **envp = ex_read_argv(envfile);   /* may be NULL: then inherit */
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int o = open(outfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        int e = open(errfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (o < 0 || e < 0) _exit(125);
        /* ipc, uts and net first; mount and pid last, because after those two
         * the paths and the process table are the container's. */
        if (ex_enter(cpid, "ipc") != 0) _exit(126);
        if (ex_enter(cpid, "uts") != 0) _exit(126);
        if (ex_enter(cpid, "net") != 0) _exit(126);
        if (ex_enter(cpid, "pid") != 0) _exit(126);
        if (ex_enter(cpid, "mnt") != 0) _exit(126);
        pid_t inner = fork();          /* the pid namespace needs a child */
        if (inner < 0) _exit(125);
        if (inner > 0) {
            int st = 0;
            if (waitpid(inner, &st, 0) < 0) _exit(125);
            _exit(WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
        }
        dup2(o, 1); dup2(e, 2); close(o); close(e);
        if (cwd && cwd[0]) { if (chdir(cwd) != 0) chdir("/"); } else chdir("/");
        /* execvpe is glibc's; everywhere else the environment is set first and
         * execvp inherits it. Same result, and it compiles on both. */
        if (envp) for (char **e = envp; *e; e++) {
            char *eq = strchr(*e, '=');
            if (eq) { *eq = 0; setenv(*e, eq + 1, 1); *eq = '='; }
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    return (int)pid;
}

/* The processes in a container, read from the HOST's process table.
 *
 * `docker top` in a container whose image has no `ps` still has to answer, and
 * running something inside it to find out would be a different question. Two
 * processes are in the same container when they are in the same pid
 * namespace, and /proc says which that is.
 */
static _Thread_local char ST_TOP[16384];
const char *st_top(int cpid) {
    ST_TOP[0] = 0;
    char want[64];
    struct stat ns;
    char p[256];
    snprintf(p, sizeof p, "/proc/%d/ns/pid", cpid);
    if (stat(p, &ns) != 0) return ST_TOP;
    snprintf(want, sizeof want, "%llu", (unsigned long long)ns.st_ino);

    DIR *d = opendir("/proc");
    if (!d) return ST_TOP;
    struct dirent *e;
    size_t o = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        struct stat s2;
        snprintf(p, sizeof p, "/proc/%s/ns/pid", e->d_name);
        if (stat(p, &s2) != 0) continue;
        char got[64];
        snprintf(got, sizeof got, "%llu", (unsigned long long)s2.st_ino);
        if (strcmp(got, want) != 0) continue;
        snprintf(p, sizeof p, "/proc/%s/cmdline", e->d_name);
        FILE *f = fopen(p, "r");
        char cmd[512] = {0};
        if (f) {
            size_t n = fread(cmd, 1, sizeof cmd - 1, f);
            fclose(f);
            for (size_t i = 0; i + 1 < n; i++) if (cmd[i] == 0) cmd[i] = ' ';
            cmd[n > 0 ? n : 0] = 0;
        }
        /* JSON, escaped the little that can appear in a command line here. */
        char row[768];
        size_t ri = 0;
        ri += (size_t)snprintf(row + ri, sizeof row - ri, "%s[\"%s\",\"", o ? "," : "", e->d_name);
        for (const char *c = cmd; *c && ri + 8 < sizeof row; c++) {
            if (*c == '"' || *c == '\\') row[ri++] = '\\';
            else if ((unsigned char)*c < 32) continue;
            row[ri++] = *c;
        }
        ri += (size_t)snprintf(row + ri, sizeof row - ri, "\"]");
        if (o + ri + 1 >= sizeof ST_TOP) break;
        memcpy(ST_TOP + o, row, ri);
        o += ri;
        ST_TOP[o] = 0;
    }
    closedir(d);
    return ST_TOP;
}

/* A file whose SIZE IS A LIE.
 *
 * Everything under /sys/fs/cgroup reports st_size 0 and then hands over bytes
 * when read. A reader that asks stat how big it is and then reads that many
 * gets nothing at all -- which is what `docker stats` reported: zero memory,
 * zero pids, from files that were right there with the numbers in them.
 * Read until EOF instead. */
static _Thread_local char ST_SMALL[8192];
const char *st_read_small(const char *path) {
    ST_SMALL[0] = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return ST_SMALL;
    size_t o = 0;
    ssize_t n;
    while (o + 1 < sizeof ST_SMALL && (n = read(fd, ST_SMALL + o, sizeof ST_SMALL - 1 - o)) > 0)
        o += (size_t)n;
    ST_SMALL[o] = 0;
    close(fd);
    return ST_SMALL;
}

/* The same, with a pipe for stdin: returns the WRITE END of that pipe and
 * writes the child's pid into `pidfile`. -1 on failure, and then the pidfile
 * is left empty rather than holding a pid that never existed. */
int ex_spawn_in(int cpid, const char *argvfile, const char *envfile,
                const char *cwd, const char *outfile, const char *errfile,
                const char *pidfile) {
    FILE *pf = fopen(pidfile, "w");
    if (pf) { fputs("", pf); fclose(pf); }
    char **argv = ex_read_argv(argvfile);
    if (!argv) return -1;
    char **envp = ex_read_argv(envfile);
    int p[2];
    if (pipe(p) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return -1; }
    if (pid == 0) {
        close(p[1]);
        int o = open(outfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        int e = open(errfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (o < 0 || e < 0) _exit(125);
        if (ex_enter(cpid, "ipc") != 0) _exit(126);
        if (ex_enter(cpid, "uts") != 0) _exit(126);
        if (ex_enter(cpid, "net") != 0) _exit(126);
        if (ex_enter(cpid, "pid") != 0) _exit(126);
        if (ex_enter(cpid, "mnt") != 0) _exit(126);
        pid_t inner = fork();
        if (inner < 0) _exit(125);
        if (inner > 0) {
            int st = 0;
            if (waitpid(inner, &st, 0) < 0) _exit(125);
            _exit(WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
        }
        dup2(p[0], 0); dup2(o, 1); dup2(e, 2);
        close(p[0]); close(o); close(e);
        if (cwd && cwd[0]) { if (chdir(cwd) != 0) chdir("/"); } else chdir("/");
        if (envp) for (char **v = envp; *v; v++) {
            char *eq = strchr(*v, '=');
            if (eq) { *eq = 0; setenv(*v, eq + 1, 1); *eq = '='; }
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    close(p[0]);
    pf = fopen(pidfile, "w");
    if (pf) { fprintf(pf, "%d", (int)pid); fclose(pf); }
    return p[1];
}

/* Writing the arena to the pipe is tcp_write's job, not a shim's: the "pointer"
 * a Mere program holds is an OFFSET into the runtime's own buffer, and only the
 * runtime knows where that buffer is. A shim that took it for an address wrote
 * from whatever happened to be there -- and read as success. */

/* Put the machine away, from inside it.
 *
 * Killing the VMM loses whatever the guest had not written yet: its root
 * filesystem commits on its own schedule, and a machine stopped a second after
 * a container was created came back without it. A stop has to be a stop, not
 * an interruption.
 *
 * So the daemon flushes and powers the machine off, and the VMM sees PSCI
 * SYSTEM_OFF -- the same path a guest takes when its init finishes, which is
 * already the one this project tests.
 *
 * Anybody who can reach this socket can do this. That is not a new power: the
 * same socket starts containers, and a container can be given the machine. */
#ifdef __linux__
#include <sys/reboot.h>
int st_shutdown(void) {
    sync();
    sync();
    reboot(RB_POWER_OFF);
    return -1;                 /* only reached if it was refused */
}
#else
int st_shutdown(void) { sync(); return -1; }
#endif

/* base64, the other way. `docker login` and every pull that carries
 * credentials send X-Registry-Auth: base64 of a small JSON object. Encoding
 * was already here for the archive routes; this is its counterpart. */
static int st_b64v(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}
static _Thread_local char ST_UNB64[8192];
const char *st_unb64(const char *in) {
    size_t o = 0;
    int acc = 0, bits = 0;
    for (const char *p = in; *p && o + 1 < sizeof ST_UNB64; p++) {
        int v = st_b64v((unsigned char)*p);
        if (v < 0) continue;                 /* padding and whitespace */
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            ST_UNB64[o++] = (char)((acc >> bits) & 0xFF);
        }
    }
    ST_UNB64[o] = 0;
    return ST_UNB64;
}

/* A monotonic millisecond, for asking WHICH STEP is slow rather than which
 * step ran. unix_time is seconds and a create takes less than one. */
#include <time.h>
int st_mono_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int)((t.tv_sec % 1000000) * 1000 + t.tv_nsec / 1000000);
}

/* Has this child finished, and with what?
 *
 * -1 means it is still running; anything else is its exit status. WNOHANG, so
 * one thread can ask about many children without blocking on any of them --
 * which is the difference between one supervisor for the whole daemon and one
 * thread per container. A thread per container is not a small cost: the accept
 * loop creates a thread per connection too, and when the runtime would not
 * make another the daemon stopped accepting anything at all. */
int st_reap_pid(int pid) {
    int st = 0;
    pid_t r = waitpid((pid_t)pid, &st, WNOHANG);
    if (r == 0) return -1;                       /* still running */
    if (r < 0) return -2;                        /* not ours, or already reaped */
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
    return -2;
}

/* A write that reports failure instead of ending the process.
 *
 * Mere's write_file raises, and in a daemon a raise is not an error return: it
 * is the end of the program. Store writes happen while other requests are
 * removing the very directories they write into -- a lease taken while
 * thirty-six containers are being deleted -- and the daemon died mid-removal
 * with a path as its last word, twice, once after a file_exists guard that the
 * race simply stepped through. */
int st_write_str(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    size_t n = strlen(text);
    ssize_t w = n == 0 ? 0 : write(fd, text, n);
    close(fd);
    return w < 0 ? -1 : 0;
}
