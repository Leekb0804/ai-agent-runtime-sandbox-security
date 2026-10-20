/*
 * test_kill_session.c
 *
 * kill.c 의 단위 테스트: 결과가 verdicts.jsonl 에 어떻게 기록되는지, 감시 해제 콜백이 언제 불리는지,
 * 관찰 모드(kill_set_mode)에서 종료하지 않고 would_kill 만 기록하는지.
 * 커널 프로그램, libbpf, sudo 가 필요 없다. 진짜 /sys/fs/cgroup 대신 임시 폴더를 kill_session_at 에 넘긴다.
 *
 * 임시 폴더 구조 (<tmp> 는 mkdtemp 로 만든 폴더):
 *   <tmp>/cg/mycontainer-123/cgroup.kill        가짜 cgroup (sent 용. cgroup_id = 이 디렉토리의 inode)
 *   <tmp>/cg/mycontainer-789/                   cgroup.kill 이 없는 가짜 cgroup (failed 용)
 *   <tmp>/sess/by-cgroup/<inode> -> ../20261020-101010-123  등 세션 링크
 *   (456 세션은 cgroup 디렉토리가 없다 -> already_gone, 링크가 없는 cgroup 은 _unattributed -> skipped)
 *
 * --wrap=kill_cgroup_at 으로 링크해서 kill.c 가 kill_cgroup_at 을 부른 횟수를 센다 (build.sh 참고).
 * 종료 코드: 0 통과, 1 실패, 2 환경 오류
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "kill.h"
#include "kill_cgroup.h"
#include "session_log.h"

static int failures;

#define CHECK(cond, name) do { \
    if (cond) printf("PASS: %s\n", name); \
    else { printf("FAIL: %s\n", name); failures++; } \
} while (0)

/* ---------- kill_cgroup_at 호출 횟수 (링커 --wrap) ---------- */
struct kill_outcome __real_kill_cgroup_at(const char *cgroup_root, const char *session_id, __u64 cgroup_id);

static int real_calls;

struct kill_outcome __wrap_kill_cgroup_at(const char *cgroup_root, const char *session_id, __u64 cgroup_id)
{
    real_calls++;
    return __real_kill_cgroup_at(cgroup_root, session_id, cgroup_id);
}

/* ---------- 가짜 감시 해제 콜백 ---------- */
static int uw_calls;
static __u64 uw_last;
static void *uw_ctx;
static int uw_rc;                 /* 콜백이 돌려줄 값. 0 이 아니면 실패를 흉내 낸다 */
static int uw_marker;             /* ctx 가 그대로 전달되는지 보려는 주소 */

static int fake_unwatch(__u64 cgroup_id, void *ctx)
{
    uw_calls++;
    uw_last = cgroup_id;
    uw_ctx = ctx;
    return uw_rc;
}

/* ---------- 준비와 도우미 ---------- */
static char base[] = "/tmp/myc_ks_test.XXXXXX";
static char cgroot[512], sessroot[512];

#define SID_SENT   "20261020-101010-123"
#define SID_GONE   "20261020-101010-456"
#define SID_FAILED "20261020-101010-789"
#define CG_GONE    900001ULL       /* cgroup 디렉토리가 없는 세션 */
#define CG_UNATTR  900002ULL       /* by-cgroup 링크가 없는 cgroup */

static void die(const char *what)
{
    perror(what);
    exit(2);
}

static void mkdir_or_die(const char *p)
{
    if (mkdir(p, 0755) != 0)
        die(p);
}

/* 가짜 cgroup 디렉토리를 만들고 inode 를 돌려준다 */
static __u64 make_cg(const char *name, int with_kill)
{
    char p[600];
    snprintf(p, sizeof(p), "%s/%s", cgroot, name);
    mkdir_or_die(p);
    if (with_kill) {
        char k[700];
        snprintf(k, sizeof(k), "%s/cgroup.kill", p);
        int fd = open(k, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0)
            die(k);
        close(fd);
    }
    struct stat st;
    if (stat(p, &st) != 0)
        die(p);
    return (__u64)st.st_ino;
}

/* 세션 폴더와 by-cgroup/<cg> -> ../<sid> 링크를 만든다 */
static void make_session(const char *sid, __u64 cg)
{
    char p[600], l[600], t[200];
    snprintf(p, sizeof(p), "%s/%s", sessroot, sid);
    mkdir_or_die(p);
    snprintf(l, sizeof(l), "%s/by-cgroup/%llu", sessroot, (unsigned long long)cg);
    snprintf(t, sizeof(t), "../%s", sid);
    if (symlink(t, l) != 0)
        die(l);
}

/* 세션 폴더의 verdicts.jsonl 마지막 줄 (끝의 \n 제외). 호출한 쪽이 free */
static char *last_line(const char *sid)
{
    char p[600];
    snprintf(p, sizeof(p), "%s/%s/verdicts.jsonl", sessroot, sid);
    FILE *f = fopen(p, "r");
    if (!f)
        return NULL;
    char buf[1024], *last = NULL;
    while (fgets(buf, sizeof(buf), f)) {
        free(last);
        buf[strcspn(buf, "\n")] = '\0';
        last = strdup(buf);
    }
    fclose(f);
    return last;
}

/* s 가 suffix 로 끝나는가 */
static int ends_with(const char *s, const char *suffix)
{
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && strcmp(s + a - b, suffix) == 0;
}

/*
 * 기록이 기대한 형식인가: 머리(schema_version, type, session) 와
 * 꼬리(cgroup_id, action, result, detail, errno, reason) 를 순서까지 정확히 비교한다.
 */
static int action_record_is(const char *sid, __u64 cg, const char *action, const char *result,
                            const char *detail, int err, const char *reason)
{
    char head[256], tail[512];
    snprintf(head, sizeof(head), "{\"schema_version\":0,\"type\":\"action\",\"session\":\"%s\",\"logged_at_ms\":", sid);
    snprintf(tail, sizeof(tail),
             ",\"cgroup_id\":%llu,\"action\":\"%s\",\"result\":\"%s\",\"detail\":\"%s\",\"errno\":%d,\"reason\":\"%s\"}",
             (unsigned long long)cg, action, result, detail, err, reason);
    char *line = last_line(sid);
    int ok = line && strncmp(line, head, strlen(head)) == 0 && ends_with(line, tail);
    free(line);
    return ok;
}

/* action="kill" 기록인가 (기존 케이스들) */
static int record_is(const char *sid, __u64 cg, const char *result, const char *detail, int err,
                     const char *reason)
{
    return action_record_is(sid, cg, "kill", result, detail, err, reason);
}

/* 세션의 verdicts.jsonl 줄 수 (없으면 0) */
static int line_count(const char *sid)
{
    char p[600], buf[1024];
    snprintf(p, sizeof(p), "%s/%s/verdicts.jsonl", sessroot, sid);
    FILE *f = fopen(p, "r");
    if (!f)
        return 0;
    int n = 0;
    while (fgets(buf, sizeof(buf), f))
        n++;
    fclose(f);
    return n;
}

/* 파일 크기 (없으면 -1). 관찰 모드에서 cgroup.kill 에 아무것도 쓰지 않았는지 본다 */
static long file_size(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 ? (long)st.st_size : -1;
}

/*
 * 케이스마다 처음과 끝에 부른다. 대응 방식(전역)을 기본(kill)으로, 감시 해제 콜백과 그 기록을 처음 상태로 되돌려
 * 한 케이스가 바꾼 전역 상태가 다른 케이스에 새지 않게 한다.
 */
static void reset_case(void)
{
    kill_set_mode(KILL_MODE_KILL);
    kill_set_unwatch(fake_unwatch, &uw_marker);
    uw_calls = 0;
    uw_rc = 0;
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
    snprintf(cgroot, sizeof(cgroot), "%s/cg", base);
    snprintf(sessroot, sizeof(sessroot), "%s/sess", base);
    mkdir_or_die(cgroot);
    mkdir_or_die(sessroot);
    char p[600];
    snprintf(p, sizeof(p), "%s/by-cgroup", sessroot);
    mkdir_or_die(p);

    __u64 cg_sent = make_cg("mycontainer-123", 1);
    __u64 cg_failed = make_cg("mycontainer-789", 0);
    make_session(SID_SENT, cg_sent);
    make_session(SID_GONE, CG_GONE);
    make_session(SID_FAILED, cg_failed);
    session_log_init(sessroot);

    enum kill_status st;
    kill_set_unwatch(fake_unwatch, &uw_marker);

    /* sent: cgroup.kill 에 쓰고, 기록하고, 감시 해제를 부른다 */
    st = kill_session_at(cgroot, session_get(cg_sent), "r-sent");
    CHECK(st == KILL_STATUS_SENT && record_is(SID_SENT, cg_sent, "sent", "written", 0, "r-sent"),
          "record_sent_fields");
    CHECK(uw_calls == 1 && uw_last == cg_sent && uw_ctx == &uw_marker, "unwatch_called_on_sent_with_cgroup_id");

    /* already_gone: cgroup 디렉토리가 없다 */
    uw_calls = 0;
    st = kill_session_at(cgroot, session_get(CG_GONE), "r-gone");
    CHECK(st == KILL_STATUS_ALREADY_GONE && record_is(SID_GONE, CG_GONE, "already_gone", "enoent", ENOENT, "r-gone"),
          "record_already_gone_fields");
    CHECK(uw_calls == 0, "unwatch_not_called_on_already_gone");

    /* failed: 디렉토리와 inode 는 맞지만 cgroup.kill 이 없다 */
    uw_calls = 0;
    st = kill_session_at(cgroot, session_get(cg_failed), "r-failed");
    CHECK(st == KILL_STATUS_FAILED && record_is(SID_FAILED, cg_failed, "failed", "open_kill", ENOENT, "r-failed"),
          "record_failed_fields");
    CHECK(uw_calls == 0, "unwatch_not_called_on_failed");

    /* skipped: 세션을 못 찾았다. kill_cgroup_at 을 부르지 않는다 */
    uw_calls = 0;
    int calls_before = real_calls;
    st = kill_session_at(cgroot, session_get(CG_UNATTR), "r-unattr");
    CHECK(st == KILL_STATUS_SKIPPED && real_calls == calls_before
          && record_is(UNATTRIBUTED_ID, CG_UNATTR, "skipped", "unattributed", 0, "r-unattr"),
          "record_skipped_unattributed");
    CHECK(uw_calls == 0, "unwatch_not_called_on_skipped");

    /* 콜백을 등록하지 않아도 sent 는 그대로 동작한다 */
    kill_set_unwatch(NULL, NULL);
    uw_calls = 0;
    st = kill_session_at(cgroot, session_get(cg_sent), "r-unset");
    CHECK(st == KILL_STATUS_SENT && uw_calls == 0 && record_is(SID_SENT, cg_sent, "sent", "written", 0, "r-unset"),
          "unwatch_unset_ok");

    /* 콜백이 실패해도 결과와 기록은 sent */
    kill_set_unwatch(fake_unwatch, &uw_marker);
    uw_calls = 0;
    uw_rc = -1;
    st = kill_session_at(cgroot, session_get(cg_sent), "r-uwfail");
    CHECK(st == KILL_STATUS_SENT && uw_calls == 1 && record_is(SID_SENT, cg_sent, "sent", "written", 0, "r-uwfail"),
          "unwatch_error_keeps_sent");

    /* ---------- 관찰 모드 ---------- */
    char killfile[700];
    snprintf(killfile, sizeof(killfile), "%s/mycontainer-123/cgroup.kill", cgroot);

    /* 관찰 모드: kill_cgroup_at 을 부르지 않고, 감시 해제도 하지 않고, would_kill 한 줄만 남긴다 */
    reset_case();
    kill_set_mode(KILL_MODE_OBSERVE);
    calls_before = real_calls;
    int lines_before = line_count(SID_SENT);
    /* 앞 케이스들이 "1" 을 써 두었으므로 비운다. 같은 자리에 덮어쓰면 크기가 그대로라 쓴 것을 알 수 없기 때문이다 */
    if (truncate(killfile, 0) != 0)
        die(killfile);
    long kill_size_before = file_size(killfile);
    st = kill_session_at(cgroot, session_get(cg_sent), "r-observe");
    CHECK(st == KILL_STATUS_OBSERVED, "observe_returns_observed");
    CHECK(real_calls == calls_before, "observe_does_not_call_kill_cgroup_at");
    CHECK(uw_calls == 0, "observe_does_not_unwatch");
    CHECK(kill_size_before == 0 && file_size(killfile) == 0, "observe_does_not_write_cgroup_kill");
    CHECK(line_count(SID_SENT) == lines_before + 1
          && action_record_is(SID_SENT, cg_sent, "would_kill", "not_sent", "observe_mode", 0, "r-observe"),
          "observe_record_one_line_exact_fields");
    reset_case();

    /* 관찰 모드에서도 _unattributed 는 kill/skipped/unattributed (would_kill 이 아님). kill_cgroup_at 도 부르지 않는다 */
    reset_case();
    kill_set_mode(KILL_MODE_OBSERVE);
    calls_before = real_calls;
    st = kill_session_at(cgroot, session_get(CG_UNATTR), "r-obs-unattr");
    CHECK(st == KILL_STATUS_SKIPPED && real_calls == calls_before
          && record_is(UNATTRIBUTED_ID, CG_UNATTR, "skipped", "unattributed", 0, "r-obs-unattr"),
          "observe_unattributed_still_skipped");
    reset_case();

    /* 기본 모드로 되돌린 뒤에는 원래대로 종료한다 (관찰 모드가 남지 않는다) */
    reset_case();
    calls_before = real_calls;
    st = kill_session_at(cgroot, session_get(cg_sent), "r-back");
    CHECK(st == KILL_STATUS_SENT && real_calls == calls_before + 1 && uw_calls == 1
          && record_is(SID_SENT, cg_sent, "sent", "written", 0, "r-back"),
          "kill_mode_restored_after_observe");
    reset_case();

    /* 이 테스트가 만든 임시 폴더만 지운다 (열린 로그 파일을 먼저 닫는다) */
    session_log_close_all();
    if (nftw(base, rm_entry, 16, FTW_DEPTH | FTW_PHYS) != 0)
        perror("cleanup");

    if (failures) { printf("FAILED: %d\n", failures); return 1; }
    printf("ALL PASSED\n");
    return 0;
}
