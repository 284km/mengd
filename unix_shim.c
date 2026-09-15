/* unix_shim.c — AF_UNIX. Three functions, and that is the whole of it.
 *
 * The Mere runtime's tcp_read / tcp_write / tcp_close are plain read(2) /
 * write(2) / close(2) against the flat FFI arena, so they already work on any
 * fd. Only the three calls that name an address family are missing, which is
 * why this file is not a socket layer.
 *
 * This is what `docker.sock` needs: the Engine API daemon listens on one of
 * these (P2) and the host-side agent proxies another (P4).
 */
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>

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
    return fd;
}

int unix_accept(int fd) {
    int c = accept(fd, 0, 0);
    return c < 0 ? -1 : c;
}

int unix_connect(const char *path) {
    struct sockaddr_un a;
    int fd;
    if (fill(&a, path) != 0) return -2;
    if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return fd;
}
