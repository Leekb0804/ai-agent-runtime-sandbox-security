/*
 * kill_cgroup.h
 *
 * ===== 이 파일의 역할 =====
 * 세션 cgroup 하나를 cgroup.kill 로 종료하는 순수 함수. 세션 로그, libbpf 에 의존하지 않아서
 * 가짜 cgroup 루트(임시 폴더)로 단위 테스트한다 (test_kill.c).
 * kill_session(kill.c) 이 이 함수를 부르고 결과를 기록한다. (연결은 다음 커밋)
 *
 * ===== 왜 inode 를 확인하나 =====
 * cgroup v2 에서 cgroup 디렉토리의 inode 번호가 곧 cgroup_id 다 (mycontainer_run.c 도 st_ino 를 쓴다).
 * 세션 ID 로 만든 경로에는 이미 다른 cgroup 이 있을 수 있다 (세션이 끝나 지워지고 같은 이름이 다시 생긴 경우).
 * 그래서 디렉토리를 fd 로 연 다음 그 fd 의 inode 를 확인하고, 같은 fd 를 기준으로 cgroup.kill 을 연다.
 * 확인한 뒤 경로로 다시 열면 그 사이에 디렉토리가 바뀌어도 알 수 없다.
 *
 * ===== 하지 않는 것 =====
 * 재시도, 대기, 종료 확인(populated 0)은 하지 않는다. cgroup.kill 에 "1" 을 한 번 쓸 뿐이다.
 */
#ifndef KILL_CGROUP_H
#define KILL_CGROUP_H

#include <linux/types.h>          /* __u64 */

enum kill_result {
    KILL_SENT         = 0,        /* cgroup.kill 에 썼다 */
    KILL_ALREADY_GONE = 1,        /* 대상이 없다 (디렉토리 없음, 또는 같은 이름의 다른 cgroup). 재시도하지 않는다 */
    KILL_FAILED       = -1,       /* 그 밖의 모든 실패. 다시 시도할 수 있다 */
};

/*
 * 결과 하나.
 *   detail : 어느 단계에서 끝났는지 (정적 문자열. 해제하지 않는다)
 *            written / enoent / inode_mismatch / bad_session_id / open_root / open_dir / fstat / open_kill / write
 *   err    : 실패한 호출의 errno. 없으면 0
 */
struct kill_outcome {
    enum kill_result result;
    const char *detail;
    int err;
};

/*
 * cgroup_root 아래의 "mycontainer-<세션 ID 끝 숫자>" 를 종료한다.
 *   cgroup_root : 실제로는 /sys/fs/cgroup. 테스트는 임시 폴더를 넘긴다
 *   session_id  : 마지막 '-' 뒤가 1~10자리 숫자이고 0 으로 시작하지 않아야 한다. 아니면 파일 시스템을 건드리지 않고 실패
 *   cgroup_id   : 세션의 cgroup_id. 디렉토리 inode 가 이 값과 다르면 아무것도 쓰지 않는다
 */
struct kill_outcome kill_cgroup_at(const char *cgroup_root, const char *session_id, __u64 cgroup_id);

#endif /* KILL_CGROUP_H */
