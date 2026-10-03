/*
 * kill.h
 *
 * ===== 이 파일의 역할 =====
 * kill switch 의 인터페이스. BLOCK 판정이 나오면 판정 처리기(verdict_handler.c)가 이 함수를 부른다.
 *
 * ===== 종료되는 것과 계속되는 것 =====
 *   종료 요청을 받는 것 : BLOCK 이 난 "세션의 에이전트 프로세스들" (cgroup 안의 모든 프로세스)
 *   계속되는 것         : 로더(감시자). 다른 세션의 이벤트를 계속 받고 판정한다.
 *                         BLOCK 이 난 세션의 기록도 종료가 끝날 때까지 계속 쌓인다
 *                         (종료는 SIGTERM -> 대기 -> SIGKILL 의 시간차가 있어서 그동안 에이전트가 움직일 수 있다)
 *
 * ===== 지금은 스텁 =====
 * 4일차에는 실제로 아무것도 죽이지 않는다. "죽였을 것이다(would_kill)"를 세션 로그에 남기고
 * 화면에 알릴 뿐이다. 실제 구현(SIGTERM -> 대기 -> SIGKILL, cgroup 정리)은 3주차에 이 함수의
 * 본문만 교체한다. 호출하는 쪽(verdict_handler.c)은 바뀌지 않는다.
 *
 * ===== 3주차에 필요한 것 (미리 적어 둔다) =====
 * - 종료하려면 세션의 cgroup "경로"가 필요한데 지금 세션에는 cgroup_id 만 있다.
 *   meta.json 이나 by-cgroup 옆의 파일에 cgroup 경로를 남기는 방법을 정해야 한다.
 * - kill 이 실패하면 kill_requested 플래그를 되돌려 다시 시도할지 정해야 한다.
 * - BLOCK 이면 무조건 종료할지, 설정으로 뺄지 정해야 한다. 오탐을 측정하는 평가용으로 "BLOCK 을 기록만 하고
 *   세션은 계속 돌리는 관찰 전용 모드"가 필요해질 수 있다. 다만 이것이 기본값이 되면 이 도구의 의미가
 *   사라지므로 평가용으로만 쓰고 README 에 명시해야 한다.
 */
#ifndef KILL_H
#define KILL_H

#include "session_log.h"

/*
 * 세션 s 를 종료한다. reason 은 로그에 남길 사유(판정의 reason).
 * 반환: 0 = 요청을 처리함, 음수 = 실패
 * 호출하는 쪽이 세션당 한 번만 부르도록 보장한다 (verdict_handler.c 의 kill_requested).
 */
int kill_session(struct session *s, const char *reason);

#endif /* KILL_H */
