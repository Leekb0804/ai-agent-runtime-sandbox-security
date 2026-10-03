/*
 * verdict_handler.h
 *
 * ===== 이 파일의 역할 =====
 * 모든 탐지기의 판정이 모이는 단 하나의 처리 지점(판정 수집기).
 * 디스패처의 sink 로 등록해서 쓴다:
 *
 *     dispatcher_set_sink(handle_verdict, stdout);
 *                         └ 판정이 나오면 호출할 함수   └ ctx (아래 설명)
 *
 * 계획서의 "판정 형식 통일" 원칙: kill switch 와 세션 로그는 어느 탐지기가 냈든 판정(SUSPECT/BLOCK)만
 * 보고 같은 규칙으로 동작한다. 탐지기가 늘어도 이 파일은 바뀌지 않는다.
 *
 * ===== 판정에 따른 처리 =====
 *   SUSPECT : 기록만 한다. 정상 작업과 구분이 어려워서 세션을 멈추면 정상 작업이 끊기기 때문이다 (과잉 차단 방지).
 *             세션이 끝난 뒤 사람이 읽는 리포트는 5주차에 만든다.
 *   BLOCK   : 기록하고 세션 종료를 요청한다 (세션당 한 번만). 지금은 kill 스텁이라 실제로 죽이지 않는다.
 *
 * BLOCK 이 나와도 감시(로더)는 멈추지 않는다. 다른 세션의 이벤트를 계속 받고, BLOCK 이 난 세션의 이벤트도
 * 종료가 완료될 때까지 계속 기록한다. 멈추는 것은 "BLOCK 이 난 세션의 에이전트 프로세스"이다.
 */
#ifndef VERDICT_HANDLER_H
#define VERDICT_HANDLER_H

#include <stdio.h>
#include "dispatcher.h"           /* verdict_sink_fn 과 같은 모양 */

/*
 * 판정 처리:
 *   1. 판정을 세션의 verdicts.jsonl 에 기록 (증거를 먼저 남긴다)
 *   2. ctx 가 FILE* 이면 같은 줄을 거기에도 출력 (개발 중 화면 확인용, NULL 이면 생략)
 *   3. BLOCK 이면 kill_session() 호출. 세션당 한 번만 (여러 번 BLOCK 이 와도 종료 요청은 한 번)
 *
 * ctx 에 들어가는 값:
 *   dispatcher_set_sink 의 두 번째 인자로 맡겨 둔 값이 판정이 날 때마다 그대로 돌아온다.
 *   디스패처는 이 값이 무엇인지 모르고 보관만 한다. 이 함수가 기대하는 것은 "FILE* 또는 NULL" 뿐이다.
 *     loader.c               : stdout  -> 판정을 화면에도 출력
 *     test_verdict_handler.c : NULL    -> 화면 출력 없음
 *   타입이 void* 라서 컴파일러는 무엇이든 받아 준다. 다른 타입(예: int*)을 넘기면 FILE* 로 잘못 읽어
 *   죽으므로, 이 약속은 코드가 아니라 이 주석으로만 지켜진다.
 */
void handle_verdict(const struct event_hdr *h, size_t len,
                    const struct verdict *v, void *ctx);

#endif /* VERDICT_HANDLER_H */
