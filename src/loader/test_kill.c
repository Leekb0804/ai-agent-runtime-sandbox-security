/*
 * test_kill.c
 *
 * kill_cgroup.c 의 단위 테스트. 커널 프로그램, libbpf, 세션 로그, sudo 가 필요 없다.
 * 임시 폴더를 가짜 cgroup 루트로 쓴다. 그 안의 cgroup.kill 은 일반 파일이라
 * "1" 이 쓰였는지를 파일 내용과 크기로 확인한다. 끝나면 이 테스트가 만든 임시 폴더만 지운다.
 * 종료 코드: 0 통과, 1 실패, 2 환경 오류
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "kill_cgroup.h"

static int failures;

#define CHECK(cond, name) do { \
    if (cond) printf("PASS: %s\n", name); \
    else { printf("FAIL: %s\n", name); failures++; } \
} while (0)

static char base[] = "/tmp/myc_kill_test.XXXXXX";
static int fd_leaks;              /* kill_cgroup_at 호출 전후로 열린 fd 수가 달라진 횟수 */

static void die(const char *what)
{
    perror(what);
    exit(2);
}

/* 폴더 안의 항목 수 (. 과 .. 제외). 실패하면 -1 */
static int count_entries(const char *path)
{
    DIR *d = opendir(path);
    if (!d)
        return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0)
            n++;
    }
    closedir(d);
    return n;
}

/* 호출 전후의 /proc/self/fd 항목 수를 비교해서 fd 누수를 센다 */
static struct kill_outcome run(const char *root, const char *sid, __u64 id)
{
    int before = count_entries("/proc/self/fd");
    struct kill_outcome o = kill_cgroup_at(root, sid, id);
    int after = count_entries("/proc/self/fd");
    if (before < 0 || after != before)
        fd_leaks++;
    return o;
}

/* 결과가 기대와 같은가. err 가 -1 이면 errno 는 확인하지 않는다 */
static int is(struct kill_outcome o, enum kill_result r, const char *detail, int err)
{
    return o.result == r && o.detail && strcmp(o.detail, detail) == 0 && (err < 0 || o.err == err);
}

/* base 아래에 가짜 cgroup 루트 하나를 만든다 */
static void make_root(char *out, size_t n, const char *tag)
{
    snprintf(out, n, "%s/%s", base, tag);
    if (mkdir(out, 0755) != 0)
        die("mkdir root");
}

/* 루트 아래에 cgroup 디렉토리를 만들고 그 inode 를 돌려준다. with_kill 이면 빈 cgroup.kill 도 만든다 */
static __u64 make_cg(const char *root, const char *name, int with_kill)
{
    char p[512];
    snprintf(p, sizeof(p), "%s/%s", root, name);
    if (mkdir(p, 0755) != 0)
        die("mkdir cgroup");
    if (with_kill) {
        char k[600];
        snprintf(k, sizeof(k), "%s/cgroup.kill", p);
        int fd = open(k, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0)
            die("create cgroup.kill");
        close(fd);
    }
    struct stat st;
    if (stat(p, &st) != 0)
        die("stat cgroup");
    return (__u64)st.st_ino;
}

/* 파일 크기. 없으면 -1 */
static long file_size(const char *root, const char *name)
{
    char p[600];
    snprintf(p, sizeof(p), "%s/%s/cgroup.kill", root, name);
    struct stat st;
    if (stat(p, &st) != 0)
        return -1;
    return (long)st.st_size;
}

/* cgroup.kill 의 내용이 정확히 "1" 인가 */
static int kill_file_is_one(const char *root, const char *name)
{
    char p[600], buf[8];
    snprintf(p, sizeof(p), "%s/%s/cgroup.kill", root, name);
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    ssize_t n = read(fd, buf, sizeof(buf));
    close(fd);
    return n == 1 && buf[0] == '1';
}

/* 잘못된 세션 ID: 실패해야 하고, 루트 아래에 아무것도 쓰거나 만들지 않아야 한다 */
static void check_bad_sid(const char *root, __u64 id, const char *sid, const char *name)
{
    int before = count_entries(root);
    struct kill_outcome o = run(root, sid, id);
    CHECK(is(o, KILL_FAILED, "bad_session_id", EINVAL)
          && file_size(root, "mycontainer-123") == 0
          && count_entries(root) == before, name);
}

static int rm_entry(const char *path, const struct stat *sb, int flag, struct FTW *ftw)
{
    (void)sb; (void)flag; (void)ftw;
    return remove(path);
}

int main(void)
{
    if (!mkdtemp(base))
        die("mkdtemp");
    if (access("/dev/full", W_OK) != 0)
        die("/dev/full");

    char r[512];
    struct kill_outcome o;

    /* 정상: inode 가 맞으면 cgroup.kill 에 "1" 을 쓴다 */
    make_root(r, sizeof(r), "sent");
    __u64 id = make_cg(r, "mycontainer-123", 1);
    o = run(r, "20261020-101010-123", id);
    CHECK(is(o, KILL_SENT, "written", 0) && kill_file_is_one(r, "mycontainer-123"), "sent_writes_one");

    /* 디렉토리가 없으면 이미 끝난 세션 */
    make_root(r, sizeof(r), "nodir");
    o = run(r, "20261020-101010-123", 42);
    CHECK(is(o, KILL_ALREADY_GONE, "enoent", ENOENT), "no_dir_is_gone");

    /* 이름은 같지만 다른 cgroup: 아무것도 쓰지 않는다 (가장 중요한 안전 검사) */
    make_root(r, sizeof(r), "mismatch");
    id = make_cg(r, "mycontainer-123", 1);
    o = run(r, "20261020-101010-123", id + 1);
    CHECK(is(o, KILL_ALREADY_GONE, "inode_mismatch", 0) && file_size(r, "mycontainer-123") == 0,
          "inode_mismatch_writes_nothing");

    /* 상위 32비트만 다른 경우도 다른 cgroup 이다 (32비트로 잘라 비교하면 잡힌다) */
    o = run(r, "20261020-101010-123", id ^ (1ULL << 32));
    CHECK(is(o, KILL_ALREADY_GONE, "inode_mismatch", 0) && file_size(r, "mycontainer-123") == 0,
          "inode_mismatch_high_bits");

    /* 잘못된 세션 ID 는 파일 시스템을 건드리기 전에 거부한다 */
    make_root(r, sizeof(r), "badsid");
    id = make_cg(r, "mycontainer-123", 1);
    check_bad_sid(r, id, "", "bad_sid_empty");
    check_bad_sid(r, id, "123", "bad_sid_no_dash");
    check_bad_sid(r, id, "20261020-101010-", "bad_sid_empty_suffix");
    check_bad_sid(r, id, "20261020-101010-abc", "bad_sid_letters");
    check_bad_sid(r, id, "20261020-101010-12a", "bad_sid_mixed_digits_letters");
    check_bad_sid(r, id, "20261020-101010-0123", "bad_sid_leading_zero");
    check_bad_sid(r, id, "20261020-101010-0", "bad_sid_zero");
    check_bad_sid(r, id, "20261020-101010-12345678901", "bad_sid_too_long");
    check_bad_sid(r, id, "20261020-101010-+123", "bad_sid_sign_char");
    check_bad_sid(r, id, "20261020-101010-..", "bad_sid_dotdot");
    check_bad_sid(r, id, "20261020-101010-1/../../x", "bad_sid_traversal");

    /*
     * 이름이 진짜 cgroup 디렉토리로의 심볼릭 링크: 따라가지 않는다.
     * cgroup_id 를 링크가 가리키는 쪽의 inode 로 둔다. 링크를 따라가면 inode 가 맞아서 실제로 쓰게 되므로
     * "진짜 쪽 cgroup.kill 크기 0" 이 의미 있는 검사가 된다.
     */
    make_root(r, sizeof(r), "symlink");
    id = make_cg(r, "real", 1);
    {
        char l[600];
        snprintf(l, sizeof(l), "%s/mycontainer-5", r);
        if (symlink("real", l) != 0)
            die("symlink");
    }
    o = run(r, "20261020-101010-5", id);
    CHECK(is(o, KILL_FAILED, "open_dir", -1) && o.err != 0 && file_size(r, "real") == 0,
          "symlink_not_followed");

    /* 디렉토리와 inode 는 맞는데 cgroup.kill 이 없다: 종료하지 못했으므로 실패 (already_gone 이 아니다) */
    make_root(r, sizeof(r), "nokill");
    id = make_cg(r, "mycontainer-7", 0);
    o = run(r, "20261020-101010-7", id);
    CHECK(is(o, KILL_FAILED, "open_kill", ENOENT), "kill_file_missing_is_failed");

    /* cgroup.kill 이 디렉토리: 쓰기용으로 열 수 없다 */
    make_root(r, sizeof(r), "killdir");
    id = make_cg(r, "mycontainer-8", 0);
    {
        char k[600];
        snprintf(k, sizeof(k), "%s/mycontainer-8/cgroup.kill", r);
        if (mkdir(k, 0755) != 0)
            die("mkdir cgroup.kill");
    }
    o = run(r, "20261020-101010-8", id);
    CHECK(is(o, KILL_FAILED, "open_kill", EISDIR), "kill_file_is_dir");

    /* 쓰기 실패: cgroup.kill 을 /dev/full 로의 링크로 두면 write 가 ENOSPC 로 실패한다 */
    make_root(r, sizeof(r), "writefail");
    id = make_cg(r, "mycontainer-9", 0);
    {
        char k[600];
        snprintf(k, sizeof(k), "%s/mycontainer-9/cgroup.kill", r);
        if (symlink("/dev/full", k) != 0)
            die("symlink /dev/full");
    }
    o = run(r, "20261020-101010-9", id);
    CHECK(is(o, KILL_FAILED, "write", ENOSPC), "write_error_is_failed");

    /* cgroup 루트 자체가 없다 */
    snprintf(r, sizeof(r), "%s/no_such_root", base);
    o = run(r, "20261020-101010-123", 42);
    CHECK(is(o, KILL_FAILED, "open_root", ENOENT), "root_missing_is_failed");

    /* 위의 모든 호출에서 fd 가 남지 않았다 */
    CHECK(fd_leaks == 0, "no_fd_leak");

    /* 이 테스트가 만든 임시 폴더만 지운다. FTW_PHYS: 링크를 따라가지 않고 링크 자체를 지운다 */
    if (nftw(base, rm_entry, 16, FTW_DEPTH | FTW_PHYS) != 0)
        perror("cleanup");

    if (failures) { printf("FAILED: %d\n", failures); return 1; }
    printf("ALL PASSED\n");
    return 0;
}
