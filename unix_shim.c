/* unix_shim.c — AF_UNIX, and AF_VSOCK where there is one. Four functions.
 *
 * The Mere runtime's tcp_read / tcp_write / tcp_close are plain read(2) /
 * write(2) / close(2) against the flat FFI arena, so they already work on any
 * fd. Only the three calls that name an address family are missing, which is
 * why this file is not a socket layer.
 *
 * This is what `docker.sock` needs: the Engine API daemon listens on one of
 * these (P2) and the host-side agent proxies another (P4).
 *
 * vsock is here for the same reason and in the same shape: a daemon running
 * INSIDE a VM cannot be reached through a path on the host's filesystem, so it
 * listens on a vsock port instead and the VMM carries the stream. The accept
 * loop does not change -- accept(2) does not care which family the listening
 * fd came from -- so this adds one call, not a second socket layer.
 */
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

/* CLOSE-ON-EXEC, on every socket this daemon owns.
 *
 * A container is started with fork+exec, and without this flag the child gets
 * the listening socket and every client connection that was open at that
 * moment -- and holds them for as long as it runs. store_shim.c closes them in
 * the child as well; this is the half that does not depend on remembering to.
 *
 * accept4(SOCK_CLOEXEC) would be one call, but it is Linux-only and this file
 * is compiled on macOS too. fcntl is both, and the window between accept and
 * fcntl matters only if something execs in it -- nothing here does.
 */
static int cloexec(int fd) {
    if (fd < 0) return fd;
    int f = fcntl(fd, F_GETFD, 0);
    if (f >= 0) fcntl(fd, F_SETFD, f | FD_CLOEXEC);
    return fd;
}

static int fill(struct sockaddr_un *a, const char *path) {
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof a->sun_path) return -1;   /* 104 on macOS, 108 on Linux */
    strcpy(a->sun_path, path);
    return 0;
}

/* Bind and listen. Removes a stale socket file first, which is what every
 * daemon does and what makes a restart work. */
int unix_listen(const char *path) {
    struct sockaddr_un a;
    int fd;
    if (fill(&a, path) != 0) return -2;                  /* path too long: named, not silent */
    unlink(path);
    if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) return -1;
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    if (listen(fd, 128) < 0) { close(fd); return -1; }
    return cloexec(fd);
}

int unix_accept(int fd) {
    int c = accept(fd, 0, 0);
    return c < 0 ? -1 : cloexec(c);
}

int unix_connect(const char *path) {
    struct sockaddr_un a;
    int fd;
    if (fill(&a, path) != 0) return -2;
    if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return cloexec(fd);
}

/* AF_VSOCK, on the kernel that has it. A guest daemon binds VMADDR_CID_ANY and
 * the VMM delivers connections from the host to that port.
 *
 * Guarded because this file is also compiled on macOS, for the host-side
 * agent. Answering -3 there is a refusal that names itself; a stub that
 * returned -1 would be indistinguishable from a port already in use. */
#ifdef __linux__
#include <linux/vm_sockets.h>

int vsock_listen(int port) {
    struct sockaddr_vm a;
    int fd;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_cid = VMADDR_CID_ANY;
    a.svm_port = (unsigned)port;
    if ((fd = socket(AF_VSOCK, SOCK_STREAM, 0)) < 0) return -1;
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    if (listen(fd, 128) < 0) { close(fd); return -1; }
    return cloexec(fd);
}
#else
int vsock_listen(int port) { (void)port; return -3; }   /* no AF_VSOCK on this platform */
#endif
