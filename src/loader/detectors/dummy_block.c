/*
 * dummy_block.c
 *
 * ===== 이 파일의 역할 =====
 * 더미 탐지기. filename 이 정확히 "/tmp/trigger" 인 EXEC 에만 BLOCK 판정을 낸다.
 * 오늘은 BLOCK 판정이 로그에 찍히는지만 확인한다. 실제로 세션을 종료하는
 * kill switch 연결은 4일차 이후다.
 *
 * dummy_suspect.c 와 같은 틀(on_event / struct detector / 생성자)을 쓰되,
 * 이번에는 이벤트 "내용"(filename)을 읽어서 판단하는 점이 다르다.
 */
#include <stdio.h>
#include <string.h>               /* strncmp */
#include "detector.h"
#include "dispatcher.h"

static int on_event(const struct event_hdr *h, size_t len, struct verdict *out)
{
    /*
     * 방어적 길이 검사. 디스패처가 이미 EXEC 의 최소 길이를 검증하지만,
     * 이 함수가 다른 경로로 호출될 가능성(테스트, 이후 변경)에 대비해 한 번 더 확인한다.
     * 아래에서 구조체로 캐스팅하기 전에 "읽어도 안전한지" 보장하는 것이 목적이다.
     * 오류를 나타내는 -1 을 반환하면 디스패처가 이 탐지기의 오류로 센다.
     */
    if (len < sizeof(struct evt_exec))
        return -1;

    /*
     * 같은 주소를 헤더 포인터(h)에서 EXEC 구조체 포인터로 바꿔 해석한다.
     * evt_exec 의 첫 필드가 event_hdr 이므로 두 포인터가 가리키는 주소가 같다.
     * kind 가 EXEC 인 이벤트만 구독했으므로 이 캐스팅은 맞는 해석이다.
     */
    const struct evt_exec *e = (const struct evt_exec *)h;

    /*
     * filename 은 NUL 종료가 보장된다고 믿지 않고 최대 MAX_FILENAME 바이트까지만 비교한다.
     * strncmp 는 두 문자열이 같으면 0 을 반환한다.
     * "!= 0" 은 "같지 않다"이므로 /tmp/trigger 가 아니면 판정 없음(0)을 돌려준다.
     */
    if (strncmp(e->filename, "/tmp/trigger", MAX_FILENAME) != 0)
        return 0;

    /* 정확히 일치하면 BLOCK 판정 */
    out->level = V_BLOCK;
    snprintf(out->reason, sizeof(out->reason), "dummy: /tmp/trigger 실행");
    return 1;
}

/* 탐지기 정의. 구조는 dummy_suspect.c 와 같고 이름만 다르다. */
static struct detector det = {
    .name = "dummy_block",
    .kinds = KIND_BIT(EVT_EXEC),
    .on_event = on_event,
};

/* main() 이전에 자동 호출되어 디스패처에 등록한다 (자세한 설명은 dummy_suspect.c 참고). */
__attribute__((constructor))
static void register_me(void)
{
    register_detector(&det);
}
