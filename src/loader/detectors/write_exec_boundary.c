/*
 * write_exec_boundary.c
 *
 * ===== 이 파일의 역할 =====
 * 쓰기→실행 경계 탐지기. 세션이 쓴 파일이 exec 되었다는 이벤트(TAG_HIT)를 받아 판정한다.
 *
 *   실행자 cgroup 이 쓴 세션과 다르고 태그가 유효(10분 이내)  -> BLOCK   (세션 밖 실행)
 *   실행자 cgroup 이 쓴 세션과 다르지만 태그가 만료(10분 초과) -> SUSPECT (기록만)
 *   실행자 cgroup 이 쓴 세션과 같음 (빌드 후 실행 등)          -> SUSPECT (기록만, 오탐은 3주차에 측정)
 *
 * 헤더 cgroup_id 는 파일을 쓴 세션, payload 의 exec_cgroup_id 는 실행한 쪽이다 (event.h 의 예외 규칙).
 * 경과 시간은 같은 단조 시계(ts_ns, tag_ts_ns)의 차이라 이벤트 하나만으로 계산할 수 있다.
 * 판정은 exec 이후의 사후 판정이다. 이 탐지기는 실행 자체를 막지 못한다.
 */
#include <stdio.h>
#include <string.h>
#include "detector.h"
#include "dispatcher.h"

/* 태그 유효 시간 (ns). 쓴 지 이보다 오래된 파일의 실행은 BLOCK 으로 올리지 않는다 */
#define TAG_EXPIRE_NS (600ULL * 1000000000ULL)

static int on_event(const struct event_hdr *h, size_t len, struct verdict *out)
{
    /* 구조체로 읽기 전에 길이를 한 번 더 확인한다 (디스패처도 검증하지만 다른 경로 호출에 대비) */
    if (len < sizeof(struct evt_tag_hit))
        return -1;

    const struct evt_tag_hit *e = (const struct evt_tag_hit *)h;

    /*
     * 경과 시간(ns). 시계 이상으로 태그 시각이 이벤트 시각보다 뒤이면 음수가 되는 대신 0 으로 본다
     * (unsigned 뺄셈이 아주 큰 값으로 넘치는 것을 막는다).
     */
    unsigned long long now = (unsigned long long)h->ts_ns;
    unsigned long long tagged = (unsigned long long)e->tag_ts_ns;
    unsigned long long elapsed = (now >= tagged) ? (now - tagged) : 0;
    unsigned long long ms = elapsed / 1000000ULL;

    int outside = (e->exec_cgroup_id != h->cgroup_id);   /* 실행자가 쓴 세션 밖인가 */
    int expired = (elapsed > TAG_EXPIRE_NS);             /* 태그가 10분을 넘었나 */

    const char *why;
    if (outside && !expired) {
        out->level = V_BLOCK;
        why = "세션 밖 실행";
    } else if (outside) {
        out->level = V_SUSPECT;
        why = "세션 밖 실행, 태그 만료";
    } else {
        out->level = V_SUSPECT;
        why = "같은 세션 안 실행";
    }

    /*
     * 이유 문자열: 경과 시간을 앞에, 경로를 맨 뒤에 둔다. reason 이 128바이트라 길면 경로가 잘린다.
     * filename 은 NUL 종료를 믿지 않고 %.*s 로 최대 MAX_FILENAME 바이트까지만 읽는다.
     * 경로는 에이전트가 정할 수 있는 값이라 로그에 쓸 때 jsonl 쪽에서 이스케이프된다.
     */
    int n = snprintf(out->reason, sizeof(out->reason), "%s, 쓴 지 %llu.%03llu초: %.*s",
                     why, ms / 1000ULL, ms % 1000ULL, (int)MAX_FILENAME, e->filename);
    /* 반환값이 음수이면 변환 오류다. 128바이트를 넘어 경로가 잘리는 것은 의도한 동작이라 오류가 아니다 */
    if (n < 0)
        return -1;
    return 1;
}

/* 탐지기 정의. TAG_HIT 만 구독한다 (더미 탐지기는 EXEC 만 구독하므로 서로 영향이 없다). */
static struct detector det = {
    .name = "write_exec_boundary",
    .kinds = KIND_BIT(EVT_TAG_HIT),
    .on_event = on_event,
};

/* main() 이전에 자동 호출되어 디스패처에 등록한다. detectors 폴더에 .c 파일을 두면 build.sh 가 자동으로 포함한다. */
__attribute__((constructor))
static void register_me(void)
{
    register_detector(&det);
}
