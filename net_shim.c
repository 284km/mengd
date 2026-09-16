/* net_shim.c — the network a compose file describes.
 *
 * A container here had a network namespace with a loopback in it and nothing
 * else, so two services in one compose file could not reach each other: the
 * daemon kept a directory per network and built no wires. `docker compose up`
 * came up, said nothing, and the application could not find its database.
 *
 * What a network is, made of the parts the kernel actually has:
 *
 *   a bridge per network           br-<12 hex of the network id>
 *   a veth pair per container      one end on the bridge, one end inside
 *   an address per container       from the network's own /24
 *   a namespace made FIRST         so the wiring is finished before the
 *                                  container process exists
 *
 * The last one is the reason any of this is race-free. The namespace is
 * created and configured here, and the bundle names it by path; the runtime
 * enters it instead of making one. A container that is wired up after it
 * starts can connect before its address exists -- rarely, which is worse than
 * always.
 *
 * Addresses, links and routes go through ioctls, which are old and exact.
 * Making a veth pair is the one thing with no ioctl, so that part speaks
 * netlink: it is the only message this file has to build by hand.
 */
#ifndef __linux__
/* None of this exists anywhere else, and none of it can be approximated: a
 * bridge, a veth pair and a network namespace are Linux objects. The daemon
 * builds on macOS so its own checks can run there; a container it started
 * would be on Linux by definition. */
#include <stdio.h>
static int nw_no(void) { return -1; }
const char *nw_last_error(void) { return "no network namespaces here: this is not Linux"; }
int nw_bridge(const char *a, const char *b, const char *c) { (void)a;(void)b;(void)c; return nw_no(); }
int nw_bridge_del(const char *a) { (void)a; return nw_no(); }
int nw_bridge_add_if(const char *a, const char *b) { (void)a;(void)b; return nw_no(); }
int nw_veth(const char *a, const char *b, const char *c) { (void)a;(void)b;(void)c; return nw_no(); }
int nw_netns_add(const char *a) { (void)a; return nw_no(); }
int nw_netns_del(const char *a) { (void)a; return nw_no(); }
int nw_config_in(const char *a, const char *b, const char *c, const char *d, const char *e) {
    (void)a;(void)b;(void)c;(void)d;(void)e; return nw_no(); }
int nw_rename_in(const char *a, const char *b, const char *c) { (void)a;(void)b;(void)c; return nw_no(); }
int nw_bridge6(const char *a, const char *b, int c) { (void)a;(void)b;(void)c; return nw_no(); }
int nw_config6_in(const char *a, const char *b, const char *c, int d, const char *e) {
    (void)a;(void)b;(void)c;(void)d;(void)e; return nw_no(); }
#else
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/sockios.h>
#include <linux/rtnetlink.h>
#include <linux/veth.h>
#include <linux/if_link.h>
#include <linux/route.h>

static char NW_ERR[512];
static int nw_fail(const char *what) {
    snprintf(NW_ERR, sizeof NW_ERR, "%s: %s", what, strerror(errno));
    return -1;
}
const char *nw_last_error(void) { return NW_ERR; }

/* ---- ioctl helpers ------------------------------------------------------ */

static int nw_sock(void) { return socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0); }

static int nw_set_up(int s, const char *ifname) {
    struct ifreq r;
    memset(&r, 0, sizeof r);
    snprintf(r.ifr_name, IFNAMSIZ, "%s", ifname);
    if (ioctl(s, SIOCGIFFLAGS, &r) != 0) return nw_fail("SIOCGIFFLAGS");
    r.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (ioctl(s, SIOCSIFFLAGS, &r) != 0) return nw_fail("SIOCSIFFLAGS");
    return 0;
}

static void nw_sin(struct sockaddr *sa, const char *addr) {
    struct sockaddr_in *in = (struct sockaddr_in *)sa;
    memset(in, 0, sizeof *in);
    in->sin_family = AF_INET;
    inet_pton(AF_INET, addr, &in->sin_addr);
}

/* An address and the prefix it is in. Both, because one without the other is
 * an interface that can talk to exactly nobody. */
static int nw_addr(int s, const char *ifname, const char *addr, const char *mask) {
    struct ifreq r;
    memset(&r, 0, sizeof r);
    snprintf(r.ifr_name, IFNAMSIZ, "%s", ifname);
    nw_sin(&r.ifr_addr, addr);
    if (ioctl(s, SIOCSIFADDR, &r) != 0) return nw_fail("SIOCSIFADDR");
    nw_sin(&r.ifr_netmask, mask);
    if (ioctl(s, SIOCSIFNETMASK, &r) != 0) return nw_fail("SIOCSIFNETMASK");
    return 0;
}

/* ---- the bridge --------------------------------------------------------- */

/* Idempotent: the second container on a network finds the bridge already
 * there, and that is the normal case rather than an error. */
int nw_bridge(const char *name, const char *addr, const char *mask) {
    int s = nw_sock();
    if (s < 0) return nw_fail("socket");
    if (ioctl(s, SIOCBRADDBR, name) != 0 && errno != EEXIST) { int r = nw_fail("SIOCBRADDBR"); close(s); return r; }
    if (nw_addr(s, name, addr, mask) != 0) { close(s); return -1; }
    if (nw_set_up(s, name) != 0) { close(s); return -1; }
    close(s);
    return 0;
}

int nw_bridge_del(const char *name) {
    int s = nw_sock();
    if (s < 0) return nw_fail("socket");
    struct ifreq r;
    memset(&r, 0, sizeof r);
    snprintf(r.ifr_name, IFNAMSIZ, "%s", name);
    if (ioctl(s, SIOCGIFFLAGS, &r) != 0) { close(s); return 0; }  /* gone already */
    r.ifr_flags &= ~IFF_UP;
    ioctl(s, SIOCSIFFLAGS, &r);
    int rc = ioctl(s, SIOCBRDELBR, name);
    close(s);
    return rc == 0 ? 0 : nw_fail("SIOCBRDELBR");
}

int nw_bridge_add_if(const char *bridge, const char *ifname) {
    int s = nw_sock();
    if (s < 0) return nw_fail("socket");
    struct ifreq r;
    memset(&r, 0, sizeof r);
    snprintf(r.ifr_name, IFNAMSIZ, "%s", bridge);
    r.ifr_ifindex = (int)if_nametoindex(ifname);
    if (r.ifr_ifindex == 0) { close(s); return nw_fail("if_nametoindex"); }
    if (ioctl(s, SIOCBRADDIF, &r) != 0 && errno != EBUSY) { int rc = nw_fail("SIOCBRADDIF"); close(s); return rc; }
    int rc = nw_set_up(s, ifname);
    close(s);
    return rc;
}

/* ---- the veth pair ------------------------------------------------------ */

struct nlreq {
    struct nlmsghdr n;
    struct ifinfomsg i;
    char buf[1024];
};

static struct rtattr *nl_nest(struct nlreq *req, int type) {
    struct rtattr *a = (struct rtattr *)((char *)req + NLMSG_ALIGN(req->n.nlmsg_len));
    a->rta_type = type;
    a->rta_len = RTA_LENGTH(0);
    req->n.nlmsg_len = NLMSG_ALIGN(req->n.nlmsg_len) + RTA_LENGTH(0);
    return a;
}
static void nl_end(struct nlreq *req, struct rtattr *a) {
    a->rta_len = (char *)req + NLMSG_ALIGN(req->n.nlmsg_len) - (char *)a;
}
static void nl_put(struct nlreq *req, int type, const void *data, int len) {
    struct rtattr *a = (struct rtattr *)((char *)req + NLMSG_ALIGN(req->n.nlmsg_len));
    a->rta_type = type;
    a->rta_len = RTA_LENGTH(len);
    memcpy(RTA_DATA(a), data, (size_t)len);
    req->n.nlmsg_len = NLMSG_ALIGN(req->n.nlmsg_len) + RTA_LENGTH(len);
}

/* Both ends at once, with the far end BORN in the target namespace.
 *
 * Creating it here and moving it afterwards would leave a window in which the
 * interface is visible on the host under a name somebody else may use, and a
 * failure in between leaves a stray device with no owner. The kernel takes the
 * destination inside the peer's own attributes, so the pair never exists in
 * one place.
 *
 * By FD, not by pid: the namespace is made before the container, so at this
 * moment there is no process in it to name. That is the whole point of the
 * order -- the wiring is finished before anything can look at it. */
int nw_veth(const char *host_if, const char *peer_if, const char *nspath) {
    int nsfd = open(nspath, O_RDONLY | O_CLOEXEC);
    if (nsfd < 0) return nw_fail("open the namespace");
    int s = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (s < 0) { close(nsfd); return nw_fail("netlink socket"); }
    struct nlreq req;
    memset(&req, 0, sizeof req);
    req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL;
    req.n.nlmsg_type = RTM_NEWLINK;
    req.i.ifi_family = AF_UNSPEC;

    nl_put(&req, IFLA_IFNAME, host_if, (int)strlen(host_if) + 1);
    struct rtattr *linfo = nl_nest(&req, IFLA_LINKINFO);
    nl_put(&req, IFLA_INFO_KIND, "veth", 5);
    struct rtattr *idata = nl_nest(&req, IFLA_INFO_DATA);
    struct rtattr *peer = nl_nest(&req, VETH_INFO_PEER);
    /* The peer's own ifinfomsg sits inside the attribute, before its own
     * attributes -- this is the part of the message that is not self-evident
     * from the header layout. */
    struct ifinfomsg *pi = (struct ifinfomsg *)((char *)&req + NLMSG_ALIGN(req.n.nlmsg_len));
    memset(pi, 0, sizeof *pi);
    req.n.nlmsg_len = NLMSG_ALIGN(req.n.nlmsg_len) + sizeof(struct ifinfomsg);
    nl_put(&req, IFLA_IFNAME, peer_if, (int)strlen(peer_if) + 1);
    nl_put(&req, IFLA_NET_NS_FD, &nsfd, sizeof nsfd);
    nl_end(&req, peer);
    nl_end(&req, idata);
    nl_end(&req, linfo);

    struct sockaddr_nl kernel;
    memset(&kernel, 0, sizeof kernel);
    kernel.nl_family = AF_NETLINK;
    if (sendto(s, &req, req.n.nlmsg_len, 0, (struct sockaddr *)&kernel, sizeof kernel) < 0) {
        int r = nw_fail("netlink send"); close(s); close(nsfd); return r;
    }
    char resp[4096];
    ssize_t n = recv(s, resp, sizeof resp, 0);
    close(s);
    close(nsfd);
    if (n < 0) return nw_fail("netlink recv");
    struct nlmsghdr *h = (struct nlmsghdr *)resp;
    if (h->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(h);
        if (e->error != 0) { errno = -e->error; return nw_fail("RTM_NEWLINK veth"); }
    }
    return 0;
}

/* ---- IPv6 ----------------------------------------------------------------
 *
 * An address and a route, and neither can be an ioctl: SIOCSIFADDR is an IPv4
 * interface and there is no v6 equivalent. Everything here is netlink, which
 * this file already speaks for the veth pair.
 *
 * The addresses are a unique local prefix, fd00:<n>::/64, one prefix per
 * network and the SAME last number as the v4 address in it -- one lease, two
 * addresses, so a container's two addresses can never disagree about which
 * container it is.
 */
struct nl6 {
    struct nlmsghdr n;
    char body[512];
};

static int nl6_send(struct nl6 *req) {
    int s = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (s < 0) return nw_fail("netlink socket");
    struct sockaddr_nl k;
    memset(&k, 0, sizeof k);
    k.nl_family = AF_NETLINK;
    if (sendto(s, req, req->n.nlmsg_len, 0, (struct sockaddr *)&k, sizeof k) < 0) {
        int r = nw_fail("netlink send"); close(s); return r;
    }
    char resp[4096];
    ssize_t n = recv(s, resp, sizeof resp, 0);
    close(s);
    if (n < 0) return nw_fail("netlink recv");
    struct nlmsghdr *h = (struct nlmsghdr *)resp;
    if (h->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(h);
        /* EEXIST is the address already being there, which is the normal
         * answer on a restart and not a failure. */
        if (e->error != 0 && e->error != -EEXIST) { errno = -e->error; return nw_fail("netlink"); }
    }
    return 0;
}

static void nl6_put(struct nl6 *req, int type, const void *data, int len) {
    struct rtattr *a = (struct rtattr *)((char *)req + NLMSG_ALIGN(req->n.nlmsg_len));
    a->rta_type = type;
    a->rta_len = RTA_LENGTH(len);
    memcpy(RTA_DATA(a), data, (size_t)len);
    req->n.nlmsg_len = NLMSG_ALIGN(req->n.nlmsg_len) + RTA_LENGTH(len);
}

static int nw_addr6(const char *ifname, const char *addr, int prefixlen) {
    unsigned idx = if_nametoindex(ifname);
    if (idx == 0) return nw_fail("if_nametoindex");
    struct in6_addr a6;
    if (inet_pton(AF_INET6, addr, &a6) != 1) { errno = EINVAL; return nw_fail("inet_pton"); }
    struct nl6 req;
    memset(&req, 0, sizeof req);
    req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifaddrmsg));
    req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE;
    req.n.nlmsg_type = RTM_NEWADDR;
    struct ifaddrmsg *ifa = (struct ifaddrmsg *)NLMSG_DATA(&req.n);
    ifa->ifa_family = AF_INET6;
    ifa->ifa_prefixlen = (unsigned char)prefixlen;
    ifa->ifa_scope = 0;
    ifa->ifa_index = idx;
    nl6_put(&req, IFA_LOCAL, &a6, sizeof a6);
    nl6_put(&req, IFA_ADDRESS, &a6, sizeof a6);
    return nl6_send(&req);
}

static int nw_route6(const char *ifname, const char *gw) {
    unsigned idx = if_nametoindex(ifname);
    if (idx == 0) return nw_fail("if_nametoindex");
    struct in6_addr g;
    if (inet_pton(AF_INET6, gw, &g) != 1) { errno = EINVAL; return nw_fail("inet_pton"); }
    struct nl6 req;
    memset(&req, 0, sizeof req);
    req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct rtmsg));
    req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE;
    req.n.nlmsg_type = RTM_NEWROUTE;
    struct rtmsg *rt = (struct rtmsg *)NLMSG_DATA(&req.n);
    rt->rtm_family = AF_INET6;
    rt->rtm_dst_len = 0;                 /* ::/0 */
    rt->rtm_table = RT_TABLE_MAIN;
    rt->rtm_protocol = RTPROT_BOOT;
    rt->rtm_scope = RT_SCOPE_UNIVERSE;
    rt->rtm_type = RTN_UNICAST;
    nl6_put(&req, RTA_GATEWAY, &g, sizeof g);
    unsigned oif = idx;
    nl6_put(&req, RTA_OIF, &oif, sizeof oif);
    return nl6_send(&req);
}

/* DAD leaves a fresh address TENTATIVE for about a second, and a socket bound
 * to a tentative address fails with EADDRNOTAVAIL. A container that connects
 * the moment it starts -- which is what a compose service does -- would lose
 * that race sometimes, which is worse than always. Both ends of a veth pair
 * are made here and nobody else can hold the address, so duplicate detection
 * has nothing to find. */
static void nw_v6_sysctl(const char *ifname) {
    const char *keys[] = {"disable_ipv6", "accept_dad"};
    const char *vals[] = {"0", "0"};
    for (size_t i = 0; i < 2; i++) {
        char p[256];
        snprintf(p, sizeof p, "/proc/sys/net/ipv6/conf/%s/%s", ifname, keys[i]);
        int fd = open(p, O_WRONLY);
        if (fd < 0) continue;
        if (write(fd, vals[i], strlen(vals[i])) < 0) { /* best effort */ }
        close(fd);
    }
}

int nw_bridge6(const char *bridge, const char *addr, int prefixlen) {
    nw_v6_sysctl(bridge);
    return nw_addr6(bridge, addr, prefixlen);
}

/* Inside the container: the address, and the way out through the bridge. In a
 * child, for the same reason as everything else here -- setns is a one-way
 * door for the process that walks through it. */
int nw_config6_in(const char *nspath, const char *ifname, const char *addr,
                  int prefixlen, const char *gw) {
    pid_t pid = fork();
    if (pid < 0) return nw_fail("fork");
    if (pid == 0) {
        int nsfd = open(nspath, O_RDONLY | O_CLOEXEC);
        if (nsfd < 0) _exit(11);
        if (setns(nsfd, CLONE_NEWNET) != 0) _exit(12);
        nw_v6_sysctl("all");
        nw_v6_sysctl(ifname);
        if (nw_addr6(ifname, addr, prefixlen) != 0) _exit(13);
        if (gw && gw[0] && nw_route6(ifname, gw) != 0) _exit(14);
        _exit(0);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return nw_fail("waitpid");
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        snprintf(NW_ERR, sizeof NW_ERR, "giving %s an IPv6 address in %s failed at step %d",
                 ifname, nspath, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        return -1;
    }
    return 0;
}

/* ---- the namespace ------------------------------------------------------ */

/* A network namespace that outlives the process that made it, the way
 * `ip netns add` does it: a file to pin it to, then a child that unshares and
 * bind-mounts its own /proc/self/ns/net onto that file. The mount is what
 * keeps the namespace alive with nothing running in it. */
int nw_netns_add(const char *path) {
    int fd = open(path, O_RDONLY | O_CREAT | O_EXCL, 0444);
    if (fd < 0) {
        if (errno != EEXIST) return nw_fail("create the namespace file");
    } else close(fd);

    pid_t pid = fork();
    if (pid < 0) return nw_fail("fork");
    if (pid == 0) {
        if (unshare(CLONE_NEWNET) != 0) _exit(11);
        if (mount("/proc/self/ns/net", path, "none", MS_BIND, NULL) != 0) _exit(12);
        _exit(0);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return nw_fail("waitpid");
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        snprintf(NW_ERR, sizeof NW_ERR, "could not pin a network namespace at %s (child %d)",
                 path, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        return -1;
    }
    return 0;
}

int nw_netns_del(const char *path) {
    umount2(path, MNT_DETACH);
    unlink(path);
    return 0;
}

/* Everything that has to happen INSIDE the container's namespace: the address,
 * the interface up, loopback up, and the way out.
 *
 * In a child, because setns is a one-way door for the process that calls it --
 * a daemon that entered a container's namespace to configure it would still be
 * in there when it answered the next request. */
int nw_config_in(const char *nspath, const char *ifname, const char *addr,
                 const char *mask, const char *gw) {
    pid_t pid = fork();
    if (pid < 0) return nw_fail("fork");
    if (pid == 0) {
        int nsfd = open(nspath, O_RDONLY | O_CLOEXEC);
        if (nsfd < 0) _exit(11);
        if (setns(nsfd, CLONE_NEWNET) != 0) _exit(12);
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) _exit(13);
        struct ifreq r;
        memset(&r, 0, sizeof r);
        snprintf(r.ifr_name, IFNAMSIZ, "%s", ifname);
        nw_sin(&r.ifr_addr, addr);
        if (ioctl(s, SIOCSIFADDR, &r) != 0) _exit(14);
        nw_sin(&r.ifr_netmask, mask);
        if (ioctl(s, SIOCSIFNETMASK, &r) != 0) _exit(15);
        if (ioctl(s, SIOCGIFFLAGS, &r) != 0) _exit(16);
        r.ifr_flags |= IFF_UP | IFF_RUNNING;
        if (ioctl(s, SIOCSIFFLAGS, &r) != 0) _exit(17);
        struct ifreq lo;
        memset(&lo, 0, sizeof lo);
        snprintf(lo.ifr_name, IFNAMSIZ, "lo");
        if (ioctl(s, SIOCGIFFLAGS, &lo) == 0) {
            lo.ifr_flags |= IFF_UP | IFF_RUNNING;
            ioctl(s, SIOCSIFFLAGS, &lo);
        }
        if (gw && gw[0]) {
            struct rtentry rt;
            memset(&rt, 0, sizeof rt);
            nw_sin((struct sockaddr *)&rt.rt_dst, "0.0.0.0");
            nw_sin((struct sockaddr *)&rt.rt_genmask, "0.0.0.0");
            nw_sin((struct sockaddr *)&rt.rt_gateway, gw);
            rt.rt_flags = RTF_UP | RTF_GATEWAY;
            if (ioctl(s, SIOCADDRT, &rt) != 0) _exit(18);
        }
        _exit(0);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return nw_fail("waitpid");
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        /* The step number is the message: each _exit above is one call, so a
         * failure says which one rather than "the network did not come up". */
        snprintf(NW_ERR, sizeof NW_ERR,
                 "configuring %s in %s failed at step %d", ifname, nspath,
                 WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        return -1;
    }
    return 0;
}

/* Rename an interface. The far end of a veth pair is born with a name that has
 * to be unique on the HOST, and inside the container it should be eth0 like
 * every other container's. */
int nw_rename_in(const char *nspath, const char *from, const char *to) {
    pid_t pid = fork();
    if (pid < 0) return nw_fail("fork");
    if (pid == 0) {
        int nsfd = open(nspath, O_RDONLY | O_CLOEXEC);
        if (nsfd < 0) _exit(11);
        if (setns(nsfd, CLONE_NEWNET) != 0) _exit(12);
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) _exit(13);
        struct ifreq r;
        memset(&r, 0, sizeof r);
        snprintf(r.ifr_name, IFNAMSIZ, "%s", from);
        snprintf(r.ifr_newname, IFNAMSIZ, "%s", to);
        if (ioctl(s, SIOCSIFNAME, &r) != 0) _exit(14);
        _exit(0);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return nw_fail("waitpid");
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        snprintf(NW_ERR, sizeof NW_ERR, "renaming %s to %s in %s failed at step %d",
                 from, to, nspath, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        return -1;
    }
    return 0;
}
#endif /* __linux__ */
