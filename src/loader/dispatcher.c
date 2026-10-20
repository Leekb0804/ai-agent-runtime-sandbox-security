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
#include <stdlib.h>               /* qsort */
#include <string.h>               /* memset, strcmp */
#include "dispatcher.h"

/*
 * ---------- 내부 상태 (전역 변수) ----------
 * static 을 붙이면 "이 파일 안에서만 보이는" 변수가 된다. 다른 파일이 실수로
 * 건드리지 못하고, 이름이 겹쳐도 충돌하지 않는다.
 *
 * g_detectors      : 탐지기 포인터를 담는 고정 크기 배열 (탐지기 "본체"가 아니라 주소만 저장)
 * g_detector_count : 지금까지 등록된 탐지기 개수
 * g_sink           : 판정이 나오면 호출할 함수 (아직 지정 전이면 NULL)
 * g_sink_ctx       : sink 에 그대로 돌려줄 포인터
 *
 * 함수 밖에 선언한 static/전역 변수는 프로그램 시작 시 자동으로 0(NULL)으로 초기화된다.
 * 이 점이 중요한 이유는 register_detector 가 main() 보다 먼저(생성자에서) 호출되는데,
 * 그 시점에도 g_detector_count 가 이미 0 이라서 안전하기 때문이다.
 */
static struct detector *g_detectors[MAX_DETECTORS];
static int g_detector_count;
static verdict_sink_fn g_sink;
static void *g_sink_ctx;
/* 등록 단계에서 거부된 탐지기 개수. 0 이 아니면 로더는 시작하지 않는다 */
static int g_register_errors;

/*
 * 탐지기 등록.
 * 각 탐지기 파일(detectors/ *.c)의 __attribute__((constructor)) 함수가 main() 이전에 호출한다.
 * 배열이 가득 찼으면 등록하지 않고 경고만 남긴다.
 */
void register_detector(struct detector *d)
{
    /* 이름이 없으면 판정과 로그에서 누가 냈는지 알 수 없으므로 거부한다 */
    if (!d->name || !d->name[0]) {
        fprintf(stderr, "[dispatcher] 이름이 없는 탐지기는 등록할 수 없음\n");
        g_register_errors++;
        return;
    }

    /* 같은 이름이 이미 있으면 거부한다 (판정과 로그에서 어느 탐지기인지 구분할 수 없게 되므로). 먼저 등록된 쪽이 남는다 */
    for (int i = 0; i < g_detector_count; i++) {
        if (strcmp(g_detectors[i]->name, d->name) == 0) {
            fprintf(stderr, "[dispatcher] 같은 이름의 탐지기가 이미 등록됨, 거부: %s\n", d->name);
            g_register_errors++;
            return;
        }
    }

    if (g_detector_count >= MAX_DETECTORS) {
        fprintf(stderr, "[dispatcher] 탐지기가 너무 많음 (최대 %d개), 거부: %s\n", (int)MAX_DETECTORS, d->name);
        g_register_errors++;
        return;
    }
    g_detectors[g_detector_count++] = d;   /* 현재 개수 위치에 넣고 개수를 1 올림 (후위 증가) */
}

/* 등록 단계에서 거부된 탐지기 수. 로더가 main 시작 때 확인한다 */
int dispatcher_registration_errors(void)
{
    return g_register_errors;
}

/* 등록된 탐지기 목록을 out 에 출력한다 (이름과 구독 종류 비트마스크) */
void dispatcher_print_detectors(FILE *out)
{
    fprintf(out, "[dispatcher] 등록된 탐지기 %d개\n", g_detector_count);
    for (int i = 0; i < g_detector_count; i++)
        fprintf(out, "  - %s (kinds=0x%08x)\n", g_detectors[i]->name, g_detectors[i]->kinds);
}

/* names 의 앞 n 개 안에 name 이 있는가 */
static int name_in(const char *name, const char *const *names, int n)
{
    for (int i = 0; i < n; i++) {
        if (strcmp(names[i], name) == 0)
            return 1;
    }
    return 0;
}

/* 등록된 탐지기 중 이름이 name 인 것이 있는가 */
static int registered(const char *name)
{
    for (int i = 0; i < g_detector_count; i++) {
        if (strcmp(g_detectors[i]->name, name) == 0)
            return 1;
    }
    return 0;
}

/* 탐지기 d 를 남길까: 이름 목록이 있으면 목록에 있는 것, 없으면(기본) 시험용이 아닌 것 */
static int keep_detector(const struct detector *d, const char *const *names, int n)
{
    if (names != NULL && n > 0)
        return name_in(d->name, names, n);
    return !d->test_only;
}

/*
 * 켤 탐지기 고르기. 먼저 전부 검사하고, 문제가 없을 때만 목록을 바꾼다 (거부하면 그대로 둔다).
 * 목록을 줄일 때는 남길 것만 앞으로 당겨 담으므로 등록 순서가 유지된다.
 */
int dispatcher_select(const char *const *names, int n, char *err, size_t errlen)
{
    int use_list = (names != NULL && n > 0);

    if (use_list) {
        for (int i = 0; i < n; i++) {
            /* 이름 목록에 같은 이름이 두 번 있으면 거부 (실수일 가능성이 높고, 결과도 모호하다) */
            if (name_in(names[i], names, i)) {
                snprintf(err, errlen, "같은 탐지기 이름이 두 번 있음: %s", names[i]);
                return -1;
            }
            /* 등록되지 않은 이름이면 거부 (오타로 탐지기가 조용히 빠지는 것을 막는다) */
            if (!registered(names[i])) {
                snprintf(err, errlen, "등록되지 않은 탐지기 이름: %s", names[i]);
                return -1;
            }
        }
    }

    /* 남을 탐지기 수를 먼저 센다. 0 개면 판정이 하나도 안 나오는데 정상처럼 보이므로 거부한다 */
    int keep = 0;
    for (int i = 0; i < g_detector_count; i++) {
        if (keep_detector(g_detectors[i], names, n))
            keep++;
    }
    if (keep == 0) {
        snprintf(err, errlen, "켤 탐지기가 없음 (%s)",
                 use_list ? "이름 목록" : "기본 선택: 시험용이 아닌 탐지기가 없음");
        return -1;
    }

    /* 남길 것만 앞으로 당긴다. j 는 다음에 담을 자리 */
    int j = 0;
    for (int i = 0; i < g_detector_count; i++) {
        if (keep_detector(g_detectors[i], names, n))
            g_detectors[j++] = g_detectors[i];
    }
    g_detector_count = j;
    return 0;
}

/* qsort 비교 함수: 탐지기 이름 포인터 둘을 strcmp 로 비교한다 */
static int cmp_name(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

int dispatcher_selected_names(char *buf, size_t len)
{
    const char *sorted[MAX_DETECTORS];
    for (int i = 0; i < g_detector_count; i++)
        sorted[i] = g_detectors[i]->name;
    qsort(sorted, (size_t)g_detector_count, sizeof(sorted[0]), cmp_name);

    size_t used = 0;
    if (len == 0)
        return -1;
    buf[0] = '\0';
    for (int i = 0; i < g_detector_count; i++) {
        /* 두 번째부터는 앞에 쉼표를 붙인다. snprintf 가 돌려주는 값은 "쓰려고 한" 길이다 */
        int w = snprintf(buf + used, len - used, "%s%s", i ? "," : "", sorted[i]);
        if (w < 0 || (size_t)w >= len - used) {
            buf[0] = '\0';
            return -1;
        }
        used += (size_t)w;
    }
    return 0;
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
 *   TAG_HIT : 헤더 + payload 전체가 있어야 함
 *   그 외    : 일단 헤더만 있으면 통과 (WRITE 등은 2주차에 구조체가 정해지면 추가)
 */
static size_t min_len_for_kind(__u32 kind)
{
    switch (kind) {
    case EVT_EXEC: return sizeof(struct evt_exec);
    case EVT_TAG_HIT: return sizeof(struct evt_tag_hit);
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
    for (int i = 0; i < g_detector_count; i++) {
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
    g_detector_count = 0;
    g_register_errors = 0;                 /* 새 전역 상태는 여기서도 되돌려야 테스트 사이에 새지 않는다 */
    g_sink = NULL;
    g_sink_ctx = NULL;
}
