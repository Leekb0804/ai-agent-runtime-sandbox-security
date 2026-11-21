/*
 * test_dummy_detectors.c
 *
 * 시험용 더미 탐지기 dummy_block, dummy_suspect 의 단위 테스트. 커널 없이 합성 EXEC 이벤트를 디스패처에 넣고
 * 판정의 수준, 탐지기 이름, 이유를 검증한다. 이유는 docs/log-schema.md 의 "reason 의 계약" 문구와 정확히 같아야 한다.
 *
 * 다른 탐지기 시험과 달리 탐지기 파일 두 개를 함께 링크한다. 둘 다 EXEC 만 구독하므로 한 EXEC 에 판정이 둘 나올 수 있다.
 * 그래서 sink 는 마지막 판정 하나가 아니라 받은 판정을 모두 담고, 검사는 탐지기 이름으로 판정을 찾는다
 * (생성자 실행 순서, 즉 등록 순서에 기대지 않는다).
 * 탐지기는 생성자로 자동 등록되므로 dispatcher_reset_for_test() 를 부르면 안 된다 (등록이 지워진다).
 * dispatcher_select 를 부르지 않으므로 test_only 탐지기도 등록된 그대로 켜져 있다.
 *
 * 빌드/실행: src/build.sh 가 만든 ./test_dummy_detectors (전부 통과하면 ALL PASSED, 종료 코드 0)
 */
#include <stdio.h>
#include <string.h>
#include "detector.h"
#include "dispatcher.h"

static int failures;

#define CHECK(cond, msg) do { \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { printf("  FAIL  %s\n", msg); failures++; } \
} while (0)

/* sink 가 받은 판정을 모두 기록한다 (한 이벤트에 최대 MAX_SEEN 개) */
#define MAX_SEEN 4
static int sink_count;                          /* 받은 판정 수 */
static enum verdict_level seen_level[MAX_SEEN];  /* 판정 수준 */
static char seen_detector[MAX_SEEN][64];        /* 탐지기 이름 */
static char seen_reason[MAX_SEEN][128];         /* 이유 (복사본) */

static void test_sink(const struct event_hdr *h, size_t len,
                      const struct verdict *v, void *ctx)
{
    (void)h; (void)len; (void)ctx;
    if (sink_count < MAX_SEEN) {
        seen_level[sink_count] = v->level;
        snprintf(seen_detector[sink_count], sizeof(seen_detector[0]), "%s", v->detector);
        snprintf(seen_reason[sink_count], sizeof(seen_reason[0]), "%.*s", (int)sizeof(v->reason), v->reason);
    }
    sink_count++;                               /* 넘쳐도 개수는 센다 */
}

static void reset_sink(void)
{
    sink_count = 0;
    memset(seen_level, 0, sizeof(seen_level));
    memset(seen_detector, 0, sizeof(seen_detector));
    memset(seen_reason, 0, sizeof(seen_reason));
}

/* 이름이 name 인 탐지기의 판정 번호. 없으면 -1 */
static int find_verdict(const char *name)
{
    int n = sink_count < MAX_SEEN ? sink_count : MAX_SEEN;
    for (int i = 0; i < n; i++) {
        if (strcmp(seen_detector[i], name) == 0)
            return i;
    }
    return -1;
}

/* 합성 EXEC 를 디스패처에 넣는다 (sink 를 비우고). memset 으로 filename 의 남은 영역을 0 으로 채운다 */
static void run_exec(const char *filename)
{
    struct evt_exec x;
    memset(&x, 0, sizeof(x));
    x.hdr.kind = EVT_EXEC;
    x.hdr.pid = 400;
    x.hdr.cgroup_id = 7;
    x.hdr.ts_ns = 7000;
    snprintf(x.filename, sizeof(x.filename), "%s", filename);
    reset_sink();
    dispatch_event(&x, sizeof(x));
}

/* ===================== 테스트 1: dummy_block ===================== */
static void test_dummy_block(void)
{
    printf("[dummy_block: filename 이 정확히 /tmp/trigger 인 EXEC 만 BLOCK]\n");
    int i;

    run_exec("/tmp/trigger");
    CHECK(sink_count == 2, "/tmp/trigger EXEC 에 판정 둘 (dummy_block 과 dummy_suspect)");
    i = find_verdict("dummy_block");
    CHECK(i >= 0 && seen_level[i] == V_BLOCK, "dummy_block 의 판정은 BLOCK");
    CHECK(i >= 0 && strcmp(seen_reason[i], "dummy: /tmp/trigger 실행") == 0,
          "dummy_block 이유가 'dummy: /tmp/trigger 실행' 과 정확히 같음");

    run_exec("/tmp/triggerx");
    CHECK(sink_count == 1 && find_verdict("dummy_block") < 0,
          "/tmp/triggerx 에는 dummy_block 판정 없음 (dummy_suspect 하나만)");
}

/* ===================== 테스트 2: dummy_suspect ===================== */
static void test_dummy_suspect(void)
{
    printf("[dummy_suspect: 모든 EXEC 에 SUSPECT]\n");
    int i;

    run_exec("/bin/ls");
    i = find_verdict("dummy_suspect");
    CHECK(sink_count == 1 && i >= 0 && seen_level[i] == V_SUSPECT, "/bin/ls EXEC 에 dummy_suspect 의 SUSPECT 하나");
    CHECK(i >= 0 && strcmp(seen_reason[i], "dummy: 모든 EXEC 는 의심") == 0,
          "dummy_suspect 이유가 'dummy: 모든 EXEC 는 의심' 과 정확히 같음");
}

int main(void)
{
    dispatcher_set_sink(test_sink, NULL);   /* 탐지기는 생성자가 이미 등록했다 */
    test_dummy_block();
    test_dummy_suspect();

    printf("\n%s (실패 %d)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
