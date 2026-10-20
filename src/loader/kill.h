/*
 * kill.h
 *
 * ===== 이 파일의 역할 =====
 * kill switch 의 인터페이스. BLOCK 판정이 나오면 판정 처리기(verdict_handler.c)가 이 함수를 부른다.
 *
 * ===== 종료되는 것과 계속되는 것 =====
 *   종료되는 것 : BLOCK 이 난 "세션의 cgroup 안의 모든 프로세스" (에이전트와 관리자 mycontainer_run)
 *   계속되는 것 : 로더(감시자). 다른 세션의 이벤트를 계속 받고 판정한다.
 *
 * ===== 종료 방식 =====
 * 세션 ID 끝의 숫자로 /sys/fs/cgroup/mycontainer-<숫자> 를 찾고, 그 디렉토리의 inode 가 세션의
 * cgroup_id 와 같을 때만 cgroup.kill 에 "1" 을 한 번 쓴다 (kill_cgroup.h). SIGTERM 단계나 대기는 없다.
 * 이벤트 루프 안에서 불리므로 기다리지 않는다. 종료가 끝났는지(populated 0)는 확인하지 않는다.
 *
 * ===== 기록 =====
 * 결과는 verdicts.jsonl 에 action="kill" 한 줄로 남기고 stderr 에도 한 줄 알린다.
 *   sent         : cgroup.kill 에 썼다
 *   already_gone : 대상이 없다 (디렉토리 없음 = enoent, 같은 이름의 다른 cgroup = inode_mismatch)
 *   failed       : 그 밖의 실패. errno 를 남긴다. 다음 BLOCK 때 다시 시도한다 (verdict_handler.c)
 *   skipped      : 세션을 찾지 못해(_unattributed) 종료 대상을 알 수 없다. 시도하지 않는다
 *
 * ===== 남은 것 =====
 * BLOCK 을 기록만 하고 세션은 계속 돌리는 관찰 전용 모드(평가용)는 아직 없다. 그 기록 이름으로
 * "would_kill" 을 비워 둔다.
 */
#ifndef KILL_H
#define KILL_H

#include "session_log.h"

/*
 * kill_session 의 결과. kill_cgroup.h 의 kill_result 에 skipped 를 더한 것이다.
 * (skipped 는 cgroup 을 건드리기 전에 정해지므로 kill_cgroup_at 의 결과에는 넣지 않는다)
 * 음수(FAILED)만 "다시 시도해야 함"이다.
 */
enum kill_status {
    KILL_STATUS_SENT         = 0,
    KILL_STATUS_ALREADY_GONE = 1,
    KILL_STATUS_SKIPPED      = 2,
    KILL_STATUS_FAILED       = -1,
};

/*
 * 종료 요청이 전달된(sent) 뒤 호출되는 콜백. 그 cgroup 을 감시 대상(session_cgroups 맵)에서 지운다.
 * 관리자(mycontainer_run)가 함께 죽어서 스스로 지우지 못하기 때문이다.
 * 맵은 libbpf 로 다루므로 로더가 등록한다 (kill.c 는 libbpf 를 모른다). 반환: 0 성공, 그 밖은 실패.
 */
typedef int (*kill_unwatch_fn)(__u64 cgroup_id, void *ctx);

/* 콜백을 등록한다. NULL 이면 감시 해제를 건너뛴다 (등록하지 않은 경우도 같음) */
void kill_set_unwatch(kill_unwatch_fn fn, void *ctx);

/*
 * 세션 s 를 종료한다 (cgroup 루트는 /sys/fs/cgroup 고정). reason 은 로그에 남길 사유(판정의 reason).
 * 호출하는 쪽이 세션당 한 번만 부르도록 보장한다 (verdict_handler.c 의 kill_requested).
 */
enum kill_status kill_session(struct session *s, const char *reason);

/*
 * kill_session 과 같고 cgroup 루트만 인자로 받는다. 테스트가 임시 폴더를 넘기려고 공개한다.
 * 로더는 kill_session 만 부른다 (루트는 환경변수 등으로 바꿀 수 없다).
 */
enum kill_status kill_session_at(const char *cgroup_root, struct session *s, const char *reason);

#endif /* KILL_H */
