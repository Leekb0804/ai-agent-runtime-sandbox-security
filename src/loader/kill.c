/*
 * kill.c
 *
 * kill switch. 세션의 cgroup 을 cgroup.kill 로 종료하고 결과를 기록한다 (인터페이스는 kill.h 참고).
 */
#include <stdio.h>
#include <string.h>
#include "kill.h"
#include "kill_cgroup.h"

#define CGROUP_ROOT "/sys/fs/cgroup"

static kill_unwatch_fn g_unwatch;
static void *g_unwatch_ctx;
static enum kill_mode g_mode = KILL_MODE_KILL;

void kill_set_mode(enum kill_mode mode)
{
    g_mode = mode;
}

void kill_set_unwatch(kill_unwatch_fn fn, void *ctx)
{
    g_unwatch = fn;
    g_unwatch_ctx = ctx;
}

static const char *status_str(enum kill_status st)
{
    switch (st) {
    case KILL_STATUS_SENT:         return "sent";
    case KILL_STATUS_ALREADY_GONE: return "already_gone";
    case KILL_STATUS_SKIPPED:      return "skipped";
    case KILL_STATUS_OBSERVED:     return "not_sent";
    case KILL_STATUS_FAILED:       return "failed";
    }
    return "failed";
}

static enum kill_status from_result(enum kill_result r)
{
    switch (r) {
    case KILL_SENT:         return KILL_STATUS_SENT;
    case KILL_ALREADY_GONE: return KILL_STATUS_ALREADY_GONE;
    case KILL_FAILED:       return KILL_STATUS_FAILED;
    }
    return KILL_STATUS_FAILED;
}

enum kill_status kill_session(struct session *s, const char *reason)
{
    return kill_session_at(CGROUP_ROOT, s, reason);
}

enum kill_status kill_session_at(const char *cgroup_root, struct session *s, const char *reason)
{
    enum kill_status st;
    const char *detail;
    int err;

    if (strcmp(s->id, UNATTRIBUTED_ID) == 0) {
        /* 세션 ID 가 없으면 cgroup 이름을 만들 수 없다. 추측해서 다른 cgroup 을 죽이지 않도록 시도하지 않는다 */
        st = KILL_STATUS_SKIPPED;
        detail = "unattributed";
        err = 0;
    } else if (g_mode == KILL_MODE_OBSERVE) {
        /*
         * 관찰 모드: cgroup.kill 에 쓰지 않고(kill_cgroup_at 을 부르지 않고) "종료했을 것이다"만 남긴다.
         * 감시 해제도 하지 않는다 (세션이 계속 돌므로 이후 이벤트를 계속 받아야 오탐을 셀 수 있다).
         */
        session_write_action(s, "would_kill", status_str(KILL_STATUS_OBSERVED), "observe_mode", 0, reason);
        fprintf(stderr, "[kill] (관찰 모드) 세션 %s (cgroup %llu) would_kill: %s\n",
                s->id, (unsigned long long)s->cgroup_id, reason ? reason : "");
        return KILL_STATUS_OBSERVED;
    } else {
        struct kill_outcome o = kill_cgroup_at(cgroup_root, s->id, s->cgroup_id);
        st = from_result(o.result);
        detail = o.detail;
        err = o.err;
    }

    /*
     * 판정과 같은 파일(verdicts.jsonl)에 type=action 레코드로 남겨서 "판정 -> 대응" 순서가 한눈에 보이게 한다.
     * 화면 알림은 stderr 로 낸다. stdout 은 JSON 로그용으로 남겨 두어 사람이 읽는 알림이 JSON 줄 사이에 섞이지 않게 한다.
     */
    session_write_action(s, "kill", status_str(st), detail, err, reason);
    fprintf(stderr, "[kill] 세션 %s (cgroup %llu) result=%s detail=%s errno=%d: %s\n",
            s->id, (unsigned long long)s->cgroup_id, status_str(st), detail, err, reason ? reason : "");
    if (st == KILL_STATUS_SKIPPED)
        fprintf(stderr, "[kill] !!! 세션을 찾지 못해 종료하지 못했다 (cgroup %llu). 그 cgroup 은 계속 돌고 있을 수 있다\n",
                (unsigned long long)s->cgroup_id);

    /* 감시 해제는 실제로 종료를 요청했을 때만. 실패해도 종료 결과와 기록은 바꾸지 않는다 */
    if (st == KILL_STATUS_SENT && g_unwatch) {
        if (g_unwatch(s->cgroup_id, g_unwatch_ctx) != 0)
            fprintf(stderr, "[kill] 감시 해제 실패 (cgroup %llu). session_cgroups 에 항목이 남는다\n",
                    (unsigned long long)s->cgroup_id);
    }
    return st;
}
