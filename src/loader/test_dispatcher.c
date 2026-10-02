/*
 * test_dispatcher.c
 *
 * ===== 이 파일의 역할 =====
 * 커널 없이(eBPF 로드 없이) 합성 이벤트를 직접 만들어서 디스패처와
 * JSON 이스케이프가 맞게 동작하는지 검증하는 단위 테스트다.
 * 로더와 달리 이 프로그램은 일반 사용자 권한으로 실행할 수 있다.
 *
 * ===== 중요한 설계 =====
 * dummy 탐지기 파일은 링크하지 않는다. 대신 테스트용 탐지기를 직접 만들어
 * register_detector 로 등록한다. 그래야 "몇 번 호출됐는가"를 세어서 검증할 수 있고,
 * 실제 탐지기를 바꿔도 이 테스트가 깨지지 않는다.
 *
 * 빌드/실행: src/build.sh 가 만든 ./test_dispatcher (전부 통과하면 ALL PASSED 출력, 종료 코드 0)
 */
#define _GNU_SOURCE               /* open_memstream 을 쓰기 위한 표준 확장 활성화 (헤더 include 보다 먼저) */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "detector.h"
#include "dispatcher.h"
#include "json_escape.h"

/* 실패한 검사의 개수. main 이 끝날 때 0 이 아니면 종료 코드를 1 로 낸다. */
static int failures;

/*
 * 검사 매크로. 조건이 참이면 PASS, 거짓이면 FAIL 을 출력하고 실패 개수를 올린다.
 * do { ... } while (0) 로 감싼 것은 매크로를 함수 호출처럼 한 문장으로 안전하게 쓰기 위한 관용구다.
 * 줄 끝의 \ 는 "다음 줄도 같은 매크로"라는 뜻이다.
 */
#define CHECK(cond, msg) do { \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { printf("  FAIL  %s\n", msg); failures++; } \
} while (0)

/* ===================== 테스트용 탐지기 ===================== */

/* 각 탐지기가 몇 번 호출됐는지 세는 카운터 */
static int calls_exec, calls_write, calls_bad, calls_good;

/* EXEC 만 구독하고 항상 BLOCK 판정을 내림 */
static int on_exec_only(const struct event_hdr *h, size_t len, struct verdict *v)
{
    (void)h; (void)len;
    calls_exec++;
    v->level = V_BLOCK;
    snprintf(v->reason, sizeof(v->reason), "test");
    return 1;
}

/* WRITE 만 구독하고 판정은 내지 않음 (호출 횟수만 센다) */
static int on_write_only(const struct event_hdr *h, size_t len, struct verdict *v)
{
    (void)h; (void)len; (void)v;
    calls_write++;
    return 0;
}

/* 항상 오류(-1)를 반환 -> 연속 오류로 비활성화되는지 확인하기 위함 */
static int always_error(const struct event_hdr *h, size_t len, struct verdict *v)
{
    (void)h; (void)len; (void)v;
    calls_bad++;
    return -1;
}

/* 항상 정상이고 SUSPECT 를 냄 -> 오류 탐지기가 있어도 계속 호출되는지 확인하기 위함 */
static int always_ok(const struct event_hdr *h, size_t len, struct verdict *v)
{
    (void)h; (void)len;
    calls_good++;
    v->level = V_SUSPECT;
    snprintf(v->reason, sizeof(v->reason), "ok");
    return 1;
}

/* ===================== 판정 처리 함수(sink) ===================== */

/* 판정이 몇 번, 누구로부터, 어떤 수준으로 전달됐는지 기록 */
static int sink_count;
static char last_detector[64];
static enum verdict_level last_level;

static void test_sink(const struct event_hdr *h, size_t len,
                      const struct verdict *v, void *ctx)
{
    (void)h; (void)len; (void)ctx;
    sink_count++;
    snprintf(last_detector, sizeof(last_detector), "%s", v->detector);
    last_level = v->level;
}

/* 각 테스트를 시작하기 전에 카운터를 0 으로 되돌림 */
static void reset_counters(void)
{
    calls_exec = calls_write = calls_bad = calls_good = 0;
    sink_count = 0;
    last_detector[0] = '\0';
}

/*
 * 합성 EXEC 이벤트를 만든다. 실제로는 커널이 ring buffer 에 써 주는 데이터를
 * 여기서는 손으로 채워서 디스패처에 넘긴다.
 * memset 으로 전체를 0 으로 먼저 채워야 구조체의 패딩과 남은 filename 영역에
 * 쓰레기 값이 섞이지 않는다.
 */
static struct evt_exec make_exec(const char *filename)
{
    struct evt_exec e;
    memset(&e, 0, sizeof(e));
    e.hdr.kind = EVT_EXEC;
    e.hdr.pid = 100;
    e.hdr.cgroup_id = 1;
    e.hdr.payload_len = sizeof(e.filename);
    snprintf(e.filename, sizeof(e.filename), "%s", filename);
    return e;
}

/* ===================== 테스트 1: 구독한 종류에만 분배 ===================== */
static void test_subscription(void)
{
    printf("[구독한 종류에만 분배]\n");
    dispatcher_reset_for_test();          /* 이전 테스트의 등록 상태를 지운다 */
    reset_counters();

    /*
     * 탐지기를 함수 안에서 static 으로 선언한 이유: 디스패처가 이 구조체의 주소를 보관하므로
     * 함수가 끝나도 살아 있어야 한다. 다만 static 은 호출 사이에 값이 유지되므로
     * 이전 테스트가 바꾼 err_streak 와 disabled 를 직접 0 으로 되돌린다.
     */
    static struct detector a = { .name = "exec_only",  .kinds = KIND_BIT(EVT_EXEC),  .on_event = on_exec_only };
    static struct detector b = { .name = "write_only", .kinds = KIND_BIT(EVT_WRITE), .on_event = on_write_only };
    a.err_streak = b.err_streak = 0;
    a.disabled = b.disabled = 0;
    register_detector(&a);
    register_detector(&b);
    dispatcher_set_sink(test_sink, NULL);

    /* EXEC 이벤트를 보낸다 -> EXEC 구독자(a)만 호출되어야 함 */
    struct evt_exec e = make_exec("/bin/ls");
    dispatch_event(&e, sizeof(e));

    CHECK(calls_exec == 1, "EXEC 구독 탐지기가 호출됨");
    CHECK(calls_write == 0, "WRITE 구독 탐지기는 호출되지 않음");
    CHECK(sink_count == 1, "판정이 sink 로 전달됨");
    CHECK(strcmp(last_detector, "exec_only") == 0, "판정에 탐지기 이름이 채워짐");
    CHECK(last_level == V_BLOCK, "판정 수준이 전달됨");

    /* 헤더만 있는 WRITE 이벤트를 보낸다 -> WRITE 구독자(b)만 호출되어야 함 */
    struct event_hdr w;
    memset(&w, 0, sizeof(w));
    w.kind = EVT_WRITE;
    dispatch_event(&w, sizeof(w));

    CHECK(calls_write == 1, "WRITE 이벤트는 WRITE 구독자에게만 감");
    CHECK(calls_exec == 1, "EXEC 구독자는 WRITE 에 반응하지 않음");
}

/* ===================== 테스트 2: 길이와 kind 검증 ===================== */
static void test_length_validation(void)
{
    printf("[길이 검증]\n");
    dispatcher_reset_for_test();
    reset_counters();

    static struct detector a = { .name = "exec_only", .kinds = KIND_BIT(EVT_EXEC), .on_event = on_exec_only };
    a.err_streak = 0;
    a.disabled = 0;
    register_detector(&a);
    dispatcher_set_sink(test_sink, NULL);

    struct evt_exec e = make_exec("/bin/ls");

    /* 헤더보다 1바이트 짧게 알려 준다 -> 헤더조차 못 읽으니 무시되어야 함 */
    dispatch_event(&e, sizeof(struct event_hdr) - 1);
    CHECK(calls_exec == 0, "헤더보다 짧은 이벤트는 무시");

    /* EXEC 구조체보다 1바이트 짧게 알려 준다 -> filename 이 잘렸으니 무시되어야 함 */
    dispatch_event(&e, sizeof(struct evt_exec) - 1);
    CHECK(calls_exec == 0, "EXEC 구조체보다 짧은 이벤트는 무시");

    /* kind 를 비트마스크 범위 밖(99)으로 만든다 -> 무시되어야 함 (KIND_BIT 오버플로 방지) */
    e.hdr.kind = 99;
    dispatch_event(&e, sizeof(e));
    CHECK(calls_exec == 0, "범위 밖 kind 는 무시");
}

/* ===================== 테스트 3: 탐지기 오류 격리 ===================== */
static void test_error_isolation(void)
{
    printf("[탐지기 오류 격리]\n");
    dispatcher_reset_for_test();
    reset_counters();

    /* 항상 오류를 내는 탐지기(bad)와 항상 정상인 탐지기(good)를 같은 종류로 구독시킨다 */
    static struct detector bad  = { .name = "bad",  .kinds = KIND_BIT(EVT_EXEC), .on_event = always_error };
    static struct detector good = { .name = "good", .kinds = KIND_BIT(EVT_EXEC), .on_event = always_ok };
    bad.err_streak = good.err_streak = 0;
    bad.disabled = good.disabled = 0;
    register_detector(&bad);
    register_detector(&good);
    dispatcher_set_sink(test_sink, NULL);

    /* 같은 이벤트를 10번 보낸다 */
    struct evt_exec e = make_exec("/bin/ls");
    for (int i = 0; i < 10; i++)
        dispatch_event(&e, sizeof(e));

    /*
     * 기대 결과:
     *  - good 은 오류 탐지기와 상관없이 10번 모두 호출된다 (오류 격리)
     *  - bad 는 연속 오류가 임계값(5)에 도달한 순간 꺼져서 5번만 호출된다
     *  - good 의 판정 10개가 모두 sink 로 전달된다
     */
    CHECK(calls_good == 10, "오류 탐지기가 있어도 다른 탐지기는 매번 호출됨");
    CHECK(calls_bad == ERR_DISABLE_THRESHOLD, "연속 오류가 임계값에 달하면 비활성화됨");
    CHECK(sink_count == 10, "정상 탐지기의 판정은 모두 전달됨");
}

/* ===================== 테스트 4: JSON 이스케이프 ===================== */
static void test_json_escape(void)
{
    printf("[JSON 이스케이프]\n");

    /*
     * open_memstream: 파일 대신 메모리 버퍼에 쓰는 FILE* 를 만든다.
     * json_put_string 이 FILE* 에 쓰는 함수라서, 출력 결과를 문자열로 받아 비교하려고 쓴다.
     * fclose 를 해야 buf 와 sz 가 최종 값으로 확정되고, 사용 후 free(buf) 로 해제한다.
     */
    char *buf = NULL;
    size_t sz = 0;
    FILE *f = open_memstream(&buf, &sz);

    /* 입력: a"b\c<개행>d<0x01>  (C 문자열 리터럴 안의 \" \\ \n \x01 이 실제 문자로 해석됨) */
    json_put_string(f, "a\"b\\c\nd\x01", 64);
    fclose(f);
    CHECK(strcmp(buf, "\"a\\\"b\\\\c\\nd\\u0001\"") == 0,
          "따옴표, 역슬래시, 개행, 제어 문자 이스케이프");
    free(buf);

    /*
     * 로그 위조 시도 재현: 값 안에 따옴표와 개행으로 가짜 JSON 줄을 심은 파일 이름.
     * 이스케이프가 제대로 되었다면 출력에 "실제 개행 문자"가 하나도 없어야 한다
     * (개행이 남으면 로그 파서가 줄을 둘로 나눠서 읽는다).
     */
    buf = NULL; sz = 0;
    f = open_memstream(&buf, &sz);
    json_put_string(f, "x\"}\n{\"type\":\"verdict\"", 64);
    fclose(f);
    CHECK(strchr(buf, '\n') == NULL, "출력에 실제 개행이 남지 않음 (한 줄 유지)");
    free(buf);

    /*
     * NUL 로 끝나지 않는 고정 크기 배열. maxlen(4)에서 멈추지 않고 계속 읽으면
     * 배열 밖 메모리를 읽게 된다. 정상이라면 "abcd" 까지만 출력되어야 한다.
     */
    char nonul[4] = { 'a', 'b', 'c', 'd' };
    buf = NULL; sz = 0;
    f = open_memstream(&buf, &sz);
    json_put_string(f, nonul, sizeof(nonul));
    fclose(f);
    CHECK(strcmp(buf, "\"abcd\"") == 0, "NUL 이 없어도 maxlen 에서 멈춤");
    free(buf);
}

int main(void)
{
    test_subscription();
    test_length_validation();
    test_error_isolation();
    test_json_escape();

    printf("\n%s (실패 %d)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;          /* 종료 코드: 성공 0, 실패 1 (나중에 run_scenarios.sh 가 이 값을 본다) */
}
