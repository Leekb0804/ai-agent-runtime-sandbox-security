/*
 * kill_cgroup.c
 *
 * 세션 cgroup 을 inode 확인 뒤 cgroup.kill 로 종료한다 (설명은 kill_cgroup.h).
 * 모든 경로에서 연 fd 는 돌아가기 전에 닫는다. errno 는 close 가 덮어쓰기 전에 저장해 둔다.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "kill_cgroup.h"

#define SID_SUFFIX_MAX 10         /* PID 는 최대 7자리(4194304)라 10자리면 충분하다 */

static struct kill_outcome outcome(enum kill_result r, const char *detail, int err)
{
    struct kill_outcome o = { r, detail, err };
    return o;
}

/*
 * 세션 ID 의 마지막 '-' 뒤를 돌려준다. 1~10자리 숫자이고 0 으로 시작하지 않을 때만.
 * 숫자만 허용하므로 "/" 나 ".." 가 경로에 들어갈 수 없다.
 */
static const char *sid_suffix(const char *session_id)
{
    if (!session_id)
        return NULL;
    const char *dash = strrchr(session_id, '-');
    if (!dash)
        return NULL;
    const char *suf = dash + 1;
    size_t n = strlen(suf);
    if (n == 0 || n > SID_SUFFIX_MAX)
        return NULL;
    if (suf[0] < '1' || suf[0] > '9')
        return NULL;
    for (size_t i = 0; i < n; i++) {
        if (suf[i] < '0' || suf[i] > '9')
            return NULL;
    }
    return suf;
}

struct kill_outcome kill_cgroup_at(const char *cgroup_root, const char *session_id, __u64 cgroup_id)
{
    const char *suf = sid_suffix(session_id);
    if (!suf)
        return outcome(KILL_FAILED, "bad_session_id", EINVAL);

    char name[32];
    snprintf(name, sizeof(name), "mycontainer-%s", suf);

    if (!cgroup_root)
        return outcome(KILL_FAILED, "open_root", EINVAL);
    int rootfd = open(cgroup_root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (rootfd < 0)
        return outcome(KILL_FAILED, "open_root", errno);

    /* O_NOFOLLOW: 이름이 심볼릭 링크면 따라가지 않고 실패한다 (ELOOP) */
    int dirfd = openat(rootfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int e = errno;
    close(rootfd);
    if (dirfd < 0) {
        if (e == ENOENT)
            return outcome(KILL_ALREADY_GONE, "enoent", ENOENT);
        return outcome(KILL_FAILED, "open_dir", e);
    }

    struct stat st;
    if (fstat(dirfd, &st) != 0) {
        e = errno;
        close(dirfd);
        return outcome(KILL_FAILED, "fstat", e);
    }
    /* 이름은 같지만 다른 cgroup 이다. 아무것도 쓰지 않는다 */
    if ((__u64)st.st_ino != cgroup_id) {
        close(dirfd);
        return outcome(KILL_ALREADY_GONE, "inode_mismatch", 0);
    }

    /*
     * 확인한 디렉토리 fd 기준으로 연다. 여기서 ENOENT 는 already_gone 이 아니라 실패다.
     * 디렉토리는 있고 inode 도 맞는데 cgroup.kill 이 없다면 종료되지 않은 채 "없어졌다"로 넘어가게 된다.
     */
    int killfd = openat(dirfd, "cgroup.kill", O_WRONLY | O_CLOEXEC);
    e = errno;
    close(dirfd);
    if (killfd < 0)
        return outcome(KILL_FAILED, "open_kill", e);

    ssize_t w = write(killfd, "1", 1);
    e = errno;
    close(killfd);
    if (w != 1)
        return outcome(KILL_FAILED, "write", w < 0 ? e : 0);
    return outcome(KILL_SENT, "written", 0);
}
