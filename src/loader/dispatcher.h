/*
 * dispatcher.h
 *
 * ===== 이 파일의 역할 =====
 * 디스패처의 "공개 함수 목록"이다. 로더와 탐지기 파일은 이 헤더에 적힌 함수만
 * 호출하면 되고, 내부 구현(dispatcher.c)은 몰라도 된다.
 *
 * ===== 디스패처가 하는 일 =====
 *   1) 탐지기를 등록받는다               : register_detector()
 *   2) 이벤트를 받아 길이를 검증한다      : dispatch_event()
 *   3) 그 종류를 구독한 탐지기에게만 전달 : dispatch_event() 내부
 *   4) 탐지기가 낸 판정을 sink 로 넘긴다  : dispatcher_set_sink() 로 등록한 함수
 *
 * 전체 흐름:
 *   ring buffer -> handle_event -> dispatch_event -> 탐지기들 -> verdict_sink
 */
#ifndef DISPATCHER_H
#define DISPATCHER_H

#include "detector.h"

/* 등록할 수 있는 탐지기의 최대 개수. 고정 크기 배열을 쓰므로 상한이 필요하다. */
#define MAX_DETECTORS 16

/*
 * 한 탐지기가 "연속으로" 이 횟수만큼 오류를 반환하면 비활성화한다.
 * 정상 반환이 한 번이라도 나오면 카운트가 0 으로 돌아가므로,
 * 간헐적인 오류 한두 번으로 탐지기가 꺼지지는 않는다.
 */
#define ERR_DISABLE_THRESHOLD 5

/*
 * 판정 처리 함수(sink)의 타입.
 * "typedef" 로 함수 포인터 타입에 이름을 붙였다. 이렇게 하면 아래에서
 *   void dispatcher_set_sink(verdict_sink_fn fn, void *ctx);
 * 처럼 읽기 쉽게 쓸 수 있다.
 *
 * 왜 sink 를 따로 두나:
 *   디스패처는 판정이 나왔을 때 "무엇을 할지"를 모른다. 오늘은 JSON 출력,
 *   4일차에는 로그 파일 기록 + BLOCK 이면 kill switch 호출이 붙는다.
 *   이를 함수 포인터로 바깥에서 꽂으면 디스패처 코드를 고치지 않고 대응 방식을 바꿀 수 있다.
 *   (단위 테스트에서도 출력 대신 카운터를 올리는 sink 를 꽂아서 검증한다)
 *
 * 인자:
 *   h, len : 판정을 일으킨 원본 이벤트 (로그에 pid, cgroup, 파일명 등을 남기기 위함)
 *   v      : 판정 내용 (수준, 탐지기 이름, 이유)
 *   ctx    : 등록할 때 넘긴 임의의 포인터를 그대로 돌려받는 자리 (필요 없으면 NULL)
 */
typedef void (*verdict_sink_fn)(const struct event_hdr *h, size_t len,
                                const struct verdict *v, void *ctx);

/* 탐지기를 레지스트리에 추가한다. 보통 각 탐지기 파일의 생성자가 main() 전에 호출한다. */
void register_detector(struct detector *d);

/* 판정이 나왔을 때 호출할 함수를 지정한다. 지정하지 않으면 판정은 버려진다. */
void dispatcher_set_sink(verdict_sink_fn fn, void *ctx);

/*
 * 이벤트 하나를 처리한다. data/len 은 ring buffer 에서 받은 값을 그대로 넘기면 된다.
 * 길이와 kind 검증도 이 함수 안에서 하므로, 호출하는 쪽은 별도로 검증하지 않아도 된다.
 */
void dispatch_event(const void *data, size_t len);

/* 판정 수준을 "SUSPECT"/"BLOCK" 같은 문자열로 바꿔 준다 (로그 출력용). */
const char *verdict_level_str(enum verdict_level level);

/*
 * 테스트 전용. 등록된 탐지기 목록과 sink 를 비운다.
 * 테스트마다 깨끗한 상태에서 시작하려고 만든 함수이며, 실제 로더에서는 호출하지 않는다.
 */
void dispatcher_reset_for_test(void);

#endif /* DISPATCHER_H */
