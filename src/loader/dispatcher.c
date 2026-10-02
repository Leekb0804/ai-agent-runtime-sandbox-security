/*
 * dispatcher.c
 *
 * ===== 이 파일의 역할 =====
 * 탐지기 레지스트리(등록 목록)와 이벤트 분배 로직의 구현이다.
 *
 * ===== 알려진 한계 =====
 * C 에는 예외(try/catch)가 없어서 "탐지기 격리"는 오류 반환값으로만 가능하다.
 * 탐지기가 잘못된 포인터를 읽어 세그폴트를 내면 로더 프로세스 전체가 죽는다.
 * 완전한 격리는 탐지기를 별도 프로세스로 분리해야 하는데 v0.1 범위 밖이다.
 * (docs 의 "수용한 한계"에 기록할 것)
 */
#include <stdio.h>
#include <string.h>               /* memset */
#include "dispatcher.h"

/*
 * ---------- 내부 상태 (전역 변수) ----------
 * static 을 붙이면 "이 파일 안에서만 보이는" 변수가 된다. 다른 파일이 실수로
 * 건드리지 못하고, 이름이 겹쳐도 충돌하지 않는다.
 *
 * g_detectors : 탐지기 포인터를 담는 고정 크기 배열 (탐지기 "본체"가 아니라 주소만 저장)
 * g_count     : 지금까지 등록된 개수
 * g_sink      : 판정이 나오면 호출할 함수 (아직 지정 전이면 NULL)
 * g_sink_ctx  : sink 에 그대로 돌려줄 포인터
 *
 * 함수 밖에 선언한 static/전역 변수는 프로그램 시작 시 자동으로 0(NULL)으로 초기화된다.
 * 이 점이 중요한 이유는 register_detector 가 main() 보다 먼저(생성자에서) 호출되는데,
 * 그 시점에도 g_count 가 이미 0 이라서 안전하기 때문이다.
 */
static struct detector *g_detectors[MAX_DETECTORS];
static int g_count;
static verdict_sink_fn g_sink;
static void *g_sink_ctx;

/*
 * 탐지기 등록.
 * 각 탐지기 파일(detectors/ *.c)의 __attribute__((constructor)) 함수가 main() 이전에 호출한다.
 * 배열이 가득 찼으면 등록하지 않고 경고만 남긴다.
 */
void register_detector(struct detector *d)
{
    if (g_count >= MAX_DETECTORS) {
        fprintf(stderr, "[dispatcher] 탐지기가 너무 많음, 무시: %s\n", d->name);
        return;
    }
    g_detectors[g_count++] = d;   /* 현재 개수 위치에 넣고 개수를 1 올림 (후위 증가) */
}

void dispatcher_set_sink(verdict_sink_fn fn, void *ctx)
{
    g_sink = fn;
    g_sink_ctx = ctx;
}

/* enum 값을 사람이 읽는 문자열로 변환. switch 의 default 는 예상 밖의 값에 대한 안전장치. */
const char *verdict_level_str(enum verdict_level level)
{
    switch (level) {
    case V_SUSPECT: return "SUSPECT";
    case V_BLOCK:   return "BLOCK";
    default:        return "UNKNOWN";
    }
}

/*
 * 이벤트 종류별 "최소 길이".
 * 받은 바이트 수(len)가 이보다 짧은데 구조체로 캐스팅해서 읽으면 구조체 끝을 넘어
 * 엉뚱한 메모리를 읽게 된다(버퍼 오버리드). 그래서 해석하기 전에 길이를 먼저 검사한다.
 *   EXEC    : 헤더 + filename 이 모두 있어야 함
 *   그 외    : 일단 헤더만 있으면 통과 (WRITE 등은 2주차에 구조체가 정해지면 추가)
 */
static size_t min_len_for_kind(__u32 kind)
{
    switch (kind) {
    case EVT_EXEC: return sizeof(struct evt_exec);
    default:       return sizeof(struct event_hdr);
    }
}

/*
 * 이벤트 한 개 분배.
 * data 는 ring buffer 에서 받은 바이트 덩어리라 아직 "무엇인지" 모른다.
 * 그래서 검증을 단계적으로 한 뒤에야 구조체로 해석한다.
 */
void dispatch_event(const void *data, size_t len)
{
    /* 1단계: 헤더 크기조차 안 되면 kind 를 읽을 수도 없다 -> 버림 */
    if (len < sizeof(struct event_hdr))
        return;

    /* 2단계: 헤더 길이는 확인됐으니 헤더로 해석해서 kind 를 읽는다 */
    const struct event_hdr *h = data;

    /* 3단계: kind 가 비트마스크 범위(0~31) 밖이면 KIND_BIT 가 정의되지 않은 동작이 되므로 버림 */
    if (h->kind >= 32)
        return;

    /* 4단계: 그 종류의 구조체 전체 크기만큼 왔는지 확인 */
    if (len < min_len_for_kind(h->kind))
        return;

    __u32 bit = KIND_BIT(h->kind);        /* 이 이벤트 종류에 해당하는 비트 */

    /* 등록된 탐지기를 순서대로 돌면서 */
    for (int i = 0; i < g_count; i++) {
        struct detector *d = g_detectors[i];

        /* 꺼졌거나 이 종류를 구독하지 않았으면 건너뜀. continue = 이번 반복은 여기서 끝 */
        if (d->disabled || !(d->kinds & bit))
            continue;

        /*
         * 판정을 받을 그릇을 0 으로 초기화해서 탐지기에게 넘긴다.
         * 초기화하지 않으면 스택에 남아 있던 쓰레기 값이 reason 에 섞일 수 있다.
         * memset(주소, 값, 바이트 수): 그 메모리를 해당 값으로 채움.
         */
        struct verdict v;
        memset(&v, 0, sizeof(v));

        int r = d->on_event(h, len, &v);  /* 탐지기 호출 (함수 포인터를 통한 호출) */

        /* 오류(<0): 이 탐지기의 연속 오류만 세고, 다른 탐지기에는 영향을 주지 않는다 */
        if (r < 0) {
            d->err_streak++;
            if (d->err_streak >= ERR_DISABLE_THRESHOLD) {
                d->disabled = 1;
                fprintf(stderr, "[dispatcher] 연속 오류 %u회, 비활성화: %s\n",
                        d->err_streak, d->name);
            }
            continue;
        }

        /* 오류가 아니었으므로 연속 오류 기록을 초기화 */
        d->err_streak = 0;

        /* 판정 없음(0)이면 할 일이 없다 */
        if (r == 0)
            continue;

        /* 판정 있음(1): 탐지기 이름은 디스패처가 채워서 신뢰할 수 있게 하고 sink 로 전달 */
        v.detector = d->name;
        if (g_sink)
            g_sink(h, len, &v, g_sink_ctx);
    }
}

void dispatcher_reset_for_test(void)
{
    g_count = 0;
    g_sink = NULL;
    g_sink_ctx = NULL;
}
