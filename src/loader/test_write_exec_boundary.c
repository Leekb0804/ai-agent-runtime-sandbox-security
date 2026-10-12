/*
 * test_write_exec_boundary.c
 *
 * write_exec_boundary 탐지기의 단위 테스트. 커널 없이 합성 TAG_HIT 이벤트를 디스패처에 넣고
 * 판정의 수준, 탐지기 이름, 이유를 검증한다.
 *
 * test_dispatcher.c 와 달리 실제 탐지기 파일을 링크한다. 이 테스트가 검증하는 대상이 그 탐지기이기 때문이다.
 * 탐지기는 생성자로 자동 등록되므로 dispatcher_reset_for_test() 를 부르면 안 된다 (등록이 지워진다).
 *
 * 빌드/실행: src/build.sh 가 만든 ./test_write_exec_boundary (전부 통과하면 ALL PASSED, 종료 코드 0)
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

#define SEC_NS (1000000000ULL)
#define NOW_NS (5000ULL * SEC_NS)       /* 합성 이벤트의 현재 시각 */
#define EXPIRE_NS (600ULL * SEC_NS)     /* 탐지기의 만료 시간과 같은 값 (10분) */
#define OWNER_CG 7ULL                   /* 파일을 쓴 세션 */
#define OTHER_CG 9ULL                   /* 실행한 쪽 (세션 밖) */

/* sink 가 받은 판정을 기록한다 */
static int sink_count;
static enum verdict_level last_level;
static char last_detector[64];
static char last_reason[128];

static void test_sink(const struct event_hdr *h, size_t len,
                      const struct verdict *v, void *ctx)
{
    (void)h; (void)len; (void)ctx;
    sink_count++;
    last_level = v->level;
    snprintf(last_detector, sizeof(last_detector), "%s", v->detector);
    snprintf(last_reason, sizeof(last_reason), "%s", v->reason);
}

static void reset_sink(void)
{
    sink_count = 0;
    last_level = (enum verdict_level)0;
    last_detector[0] = '\0';
    last_reason[0] = '\0';
}

/*
 * 합성 TAG_HIT. exec_cg 는 실행한 쪽의 cgroup, elapsed_ns 는 쓴 뒤 지난 시간이다.
 * 헤더 cgroup_id 는 쓴 세션(OWNER_CG)이다. memset 으로 패딩과 filename 의 남은 영역을 0 으로 채운다.
 */
static struct evt_tag_hit make_hit(unsigned long long exec_cg,
                                   unsigned long long elapsed_ns, const char *path)
{
    struct evt_tag_hit e;
    memset(&e, 0, sizeof(e));
    e.hdr.kind = EVT_TAG_HIT;
    e.hdr.pid = 200;
    e.hdr.cgroup_id = OWNER_CG;
    e.hdr.ts_ns = NOW_NS;
    e.hdr.payload_len = sizeof(e) - sizeof(e.hdr);
    e.exec_cgroup_id = exec_cg;
    e.tag_ts_ns = NOW_NS - elapsed_ns;
    e.dev = 265289730;
    e.ino = 3549503;
    snprintf(e.filename, sizeof(e.filename), "%s", path);
    return e;
}

/* ===================== 테스트 1: 판정 규칙 ===================== */
static void test_decision(void)
{
    printf("[세션 밖 실행은 BLOCK, 그 외는 SUSPECT]\n");
    struct evt_tag_hit e;

    /* 세션 밖, 쓴 지 1초 -> BLOCK */
    reset_sink();
    e = make_hit(OTHER_CG, 1 * SEC_NS, "/var/lib/x/upper/tmp/trigger");
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1, "세션 밖 실행에 판정이 하나 나옴");
    CHECK(last_level == V_BLOCK, "세션 밖 실행(쓴 지 1초)은 BLOCK");
    CHECK(strcmp(last_detector, "write_exec_boundary") == 0, "판정에 탐지기 이름이 채워짐");
    CHECK(strstr(last_reason, "/var/lib/x/upper/tmp/trigger") != NULL, "이유에 파일 경로가 들어감");
    CHECK(strstr(last_reason, "1.000") != NULL, "이유에 경과 시간(1.000초)이 들어감");

    /* 같은 세션 안 실행 -> SUSPECT */
    reset_sink();
    e = make_hit(OWNER_CG, 1 * SEC_NS, "/tmp/build/a.out");
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1 && last_level == V_SUSPECT, "같은 세션 안 실행은 SUSPECT");
    CHECK(strstr(last_reason, "같은 세션") != NULL, "이때 이유는 '같은 세션 안 실행'");

    /* 세션 밖이지만 11분 지남 -> SUSPECT (태그 만료) */
    reset_sink();
    e = make_hit(OTHER_CG, 660 * SEC_NS, "/tmp/old");
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1 && last_level == V_SUSPECT, "세션 밖이라도 만료(11분)면 SUSPECT");
    CHECK(strstr(last_reason, "태그 만료") != NULL, "이때 이유는 '태그 만료'");

    /* 경계: 정확히 10분은 아직 유효 -> BLOCK, 1ns 넘으면 만료 -> SUSPECT */
    reset_sink();
    e = make_hit(OTHER_CG, EXPIRE_NS, "/tmp/edge");
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1 && last_level == V_BLOCK, "정확히 10분은 아직 유효해서 BLOCK");

    reset_sink();
    e = make_hit(OTHER_CG, EXPIRE_NS + 1, "/tmp/edge");
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1 && last_level == V_SUSPECT, "10분을 1ns 넘으면 SUSPECT");
    CHECK(strstr(last_reason, "태그 만료") != NULL, "1ns 초과도 이유는 '태그 만료'");

    /* 시계 이상: 태그 시각이 이벤트 시각보다 뒤. 경과 0 으로 보고 세션 밖이면 BLOCK */
    reset_sink();
    e = make_hit(OTHER_CG, 0, "/tmp/future");
    e.tag_ts_ns = NOW_NS + 5 * SEC_NS;
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1 && last_level == V_BLOCK, "태그 시각이 미래여도 넘치지 않고 BLOCK");
    CHECK(strstr(last_reason, "0.000") != NULL, "이때 경과 시간은 0.000초로 표시됨");
}

/* ===================== 테스트 2: 무시해야 하는 이벤트 ===================== */
static void test_ignored(void)
{
    printf("[무시해야 하는 이벤트]\n");

    /* TAG_HIT 구조체보다 1바이트 짧게 알려 준다 -> 디스패처가 버린다 */
    reset_sink();
    struct evt_tag_hit e = make_hit(OTHER_CG, 1 * SEC_NS, "/tmp/x");
    dispatch_event(&e, sizeof(e) - 1);
    CHECK(sink_count == 0, "짧은 TAG_HIT 은 판정 없음");

    /* EXEC 이벤트 -> 이 탐지기는 TAG_HIT 만 구독하므로 반응하지 않는다 */
    reset_sink();
    struct evt_exec x;
    memset(&x, 0, sizeof(x));
    x.hdr.kind = EVT_EXEC;
    x.hdr.cgroup_id = OWNER_CG;
    x.hdr.ts_ns = NOW_NS;
    snprintf(x.filename, sizeof(x.filename), "/tmp/trigger");
    dispatch_event(&x, sizeof(x));
    CHECK(sink_count == 0, "EXEC 이벤트에는 반응하지 않음");
}

/* ===================== 테스트 3: 긴 파일 이름 ===================== */
static void test_long_filename(void)
{
    printf("[긴 파일 이름]\n");
    reset_sink();
    struct evt_tag_hit e = make_hit(OTHER_CG, 1 * SEC_NS, "x");
    /* NUL 없이 filename 배열을 'A' 로 가득 채운다 (공격자가 정할 수 있는 값) */
    memset(e.filename, 'A', MAX_FILENAME);
    dispatch_event(&e, sizeof(e));
    CHECK(sink_count == 1 && last_level == V_BLOCK, "NUL 없는 긴 이름도 판정이 나옴");
    CHECK(strlen(last_reason) == sizeof(last_reason) - 1, "이유는 128바이트에서 NUL 로 끝나게 잘림");
}

int main(void)
{
    dispatcher_set_sink(test_sink, NULL);   /* 탐지기는 생성자가 이미 등록했다 */
    test_decision();
    test_ignored();
    test_long_filename();

    printf("\n%s (실패 %d)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
