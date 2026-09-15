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

/* ---- running a container ---------------------------------------------- */
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>

/* Fork, point stdout AND stderr at one log file, chdir into the bundle, and
 * exec the runtime. The parent gets the pid back.
 *
 * Both streams go to the same file. Docker's log stream tags each frame as
 * stdout or stderr and this cannot tell them apart, which is a real difference
 * from the real daemon and is written down in the README rather than papered
 * over: everything comes back tagged stdout.
 */
int st_spawn_logged(const char *path, const char *a1, const char *a2,
                    const char *cwd, const char *logfile) {
    pid_t p = fork();
    if (p < 0) return -1;
    if (p > 0) return (int)p;

    int fd = open(logfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) _exit(125);
    dup2(fd, 1); dup2(fd, 2);
    if (fd > 2) close(fd);
    if (cwd && cwd[0] && chdir(cwd) != 0) _exit(126);
    char *argv[4] = { (char *)path, (char *)a1, (char *)a2, NULL };
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
