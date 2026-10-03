/*
 * session_log.h
 *
 * ===== 이 파일의 역할 =====
 * "이 이벤트가 어느 세션의 것인가"를 찾고, 세션별 로그 파일(events.jsonl, verdicts.jsonl)에
 * 기록한다.
 *
 * ===== 먼저, "세션"이 무엇인가 =====
 * 세션은 프로세스도 아니고 감시 프로그램(로더)도 아니다.
 *
 *     세션 = agent-run 한 번이 만든 컨테이너(cgroup)와, 그 안의 모든 프로세스와, 그 기록
 *
 * 컨테이너에 "이름표(세션 ID)와 기록장(sessions/ 아래 폴더)"을 붙인 것이다. 커널이 아는 것은
 * 프로세스와 cgroup 뿐이고, "이 cgroup 은 이 세션"이라는 대응은 우리가 직접 만들어 둔 것이다.
 *
 *     로더(myc_loader) : 감시자. 세션 바깥에서 계속 떠 있으며 여러 세션의 이벤트를 받는다.
 *     세션             : 감시 "대상". agent-run 시작부터 종료까지. 에이전트가 만드는 모든 프로세스가 들어 있다.
 *
 * 세션이 끝나도 기록은 남는다 (sessions/<세션ID>/ 폴더). 그 기록이 사후 검토와 리포트의 재료다.
 *
 * ===== 세션 ID 와 cgroup ID 는 다른 것이다 =====
 *   세션 ID   : run_container.sh 가 "시작 시각-스크립트 PID" 로 만든다. 예: 20261002-115607-1095185
 *               영구적인 로그의 이름이다.
 *   cgroup ID : 커널이 cgroup 에 붙인 번호. 이벤트에 들어 있는 유일한 식별자이다.
 *               컨테이너가 끝나 cgroup 이 삭제되면 커널에서 사라진다. 살아 있는 동안의 연결 키이다.
 * 그래서 모든 로그 레코드에 cgroup ID 가 아니라 "세션 ID" 를 직접 넣는다. cgroup 이 사라진 뒤에도
 * 레코드 하나만 보고 어느 세션인지 알 수 있어야 하기 때문이다. (cgroup ID 도 같이 남겨서 대조할 수 있게 한다)
 *
 * ===== 둘을 이어 주는 대응표: by-cgroup 심볼릭 링크 =====
 * 로더는 cgroup ID 만 알고, 로그는 세션 폴더에 남겨야 한다. 이 둘을 잇는 표가 필요하다.
 * 세션 ID 는 run_container.sh(bash)가 만들고 그것이 필요한 쪽은 따로 떠 있는 로더(C)다.
 * 서로 다른 프로세스라서 변수로는 전달할 수 없고, 둘이 함께 볼 수 있는 파일 시스템에 적어 둔다.
 *
 *     <root>/by-cgroup/<cgroup_id>   내용: "../<세션ID>"
 *
 * 이 링크가 무엇인지 정확히 말하면:
 *   - 변수가 아니다. 파일 시스템(디스크)에 저장되는 항목이라서 프로세스가 끝나도 남고,
 *     다른 프로세스가 볼 수 있다.
 *   - 폴더가 아니라 "파일 하나"이다. 종류가 "심볼릭 링크"(ls -l 의 맨 앞 글자 l)이고,
 *     내용이 경로 문자열 하나이다. 크기와 inode 번호도 가진다.
 *   - 그 아래에 다른 파일이 생기는 것이 아니다. by-cgroup/309013/세션ID 라는 파일은 없다.
 *     (by-cgroup/309013/ 처럼 뒤에 슬래시를 붙이면 운영체제가 링크를 "따라가서" 세션 폴더의 내용을
 *     보여 주므로 안에 뭔가 있는 것처럼 보일 뿐이다)
 *   - 일반 파일과의 차이는 "운영체제가 내용을 경로로 따라갈 수 있는가" 하나뿐이다.
 *     우리 코드는 따라가는 기능을 쓰지 않고 readlink 로 내용 글자만 읽는다. 그러니 일반 파일에
 *     세션 ID 를 적어 두어도 같은 목적은 이룬다. 링크를 고른 이유는, 만들 때 내용이 한 번에
 *     정해지고(만드는 중간에 빈 내용을 읽는 경합이 없음) 읽기도 readlink 한 번이면 되며,
 *     사람이 ls -l 로 대응표를 한눈에 볼 수 있기 때문이다.
 *
 * 만드는 곳: run_container.sh 의 두 줄 (CGROUP_ID 를 구한 직후, 세션 디렉토리를 만드는 블록 안)
 *
 *     sudo mkdir -p "/var/lib/mycontainer/sessions/by-cgroup"
 *     sudo ln -sfn "../$SESSION_ID" "/var/lib/mycontainer/sessions/by-cgroup/$CGROUP_ID"
 *                   └ 링크의 "내용"    └ 링크가 만들어질 "위치와 이름"
 *
 *     ln 의 첫 번째 인자가 곧 링크의 내용이 된다. 별도로 내용을 쓰는 단계가 없다.
 *     -s 는 심볼릭, -f 는 같은 이름이 있으면 덮어쓰기, -n 은 "같은 이름이 이미 폴더를 가리키는
 *     링크여도 그 폴더 안에 만들지 말고 링크 자체를 교체하라"는 뜻이다. -n 이 없으면 기존 세션
 *     폴더 안에 엉뚱한 링크가 생겨 폴더가 오염된다.
 *     이 두 줄이 빠지면 로더가 세션을 못 찾고 모든 기록이 _unattributed 로 간다 (에러는 나지 않는다).
 *
 * 읽는 곳: session_log.c 의 resolve_session (readlink)
 *
 * 링크는 호스트의 root 만 쓸 수 있는 경로에 있으므로 컨테이너 안의 에이전트가 건드릴 수 없다.
 *
 * ===== 세션을 못 찾으면 =====
 * 로그를 버리지 않고 <root>/_unattributed/ 에 기록한다. 이벤트에 cgroup ID 가 같이 남으므로
 * 나중에 각 세션의 meta.json 과 대조해 추적할 수 있다. (조용히 사라지는 로그가 가장 나쁘다)
 */
#ifndef SESSION_LOG_H
#define SESSION_LOG_H

#include <stdio.h>
#include <stddef.h>
#include <limits.h>
#include <linux/types.h>
#include "bpf/event.h"
#include "detector.h"

#define SESSION_ID_MAX 96
#define UNATTRIBUTED_ID "_unattributed"

/*
 * 세션 하나의 "런타임 상태". session_log.c 안에 이런 칸(slot)이 64개 있는 배열이 있다.
 * 로더는 이벤트마다 cgroup ID 로 이 칸을 찾는다. 칸에 저장해 두는 이유는 세 가지다.
 *   1) cgroup ID -> 세션 대응을 저장한다 (이벤트마다 readlink 와 stat 을 다시 하지 않으려고)
 *   2) 열어 둔 로그 파일 핸들을 저장한다 (이벤트마다 파일을 열고 닫지 않으려고)
 *   3) kill_requested 를 저장한다 (BLOCK 이 여러 번 와도 종료 요청을 한 번만 하려고)
 * 이 구조체의 값은 파일 시스템의 링크가 아니라 로더 프로세스의 "메모리"에 있다. 로더가 끝나면 사라진다.
 */
struct session {
    int in_use;                   /* 이 칸이 사용 중인가. 0 이면 비어 있어 새 세션이 쓸 수 있음 */
    __u64 cgroup_id;              /* 이 칸의 세션에 해당하는 cgroup ID (칸을 찾는 키) */
    char id[SESSION_ID_MAX];      /* 세션 ID. 못 찾았으면 "_unattributed" */
    char dir[PATH_MAX];           /* 세션 디렉토리 경로 (<root>/<세션ID>) */
    FILE *events;                 /* events.jsonl 파일 핸들 (append). 열기에 실패하면 NULL */
    FILE *verdicts;               /* verdicts.jsonl 파일 핸들 (append). 열기에 실패하면 NULL */
    int kill_requested;           /* BLOCK 으로 종료를 이미 요청했는가 (한 번만 하기 위한 멱등성 플래그) */
    unsigned long last_used;      /* 마지막으로 쓴 순번. 칸이 모자랄 때 가장 오래 안 쓴 칸을 밀어내는 기준(LRU) */
};

/*
 * 로그 쓰기 통계. "로그 쓰기가 이벤트 수신 루프를 늦추지 않는가"를 숫자로 확인하려고 모은다.
 * 로더가 종료될 때 한 줄로 출력한다.
 */
struct session_log_stats {
    unsigned long writes;         /* 기록 횟수 */
    unsigned long slow_writes;    /* 5ms 넘게 걸린 기록 */
    unsigned long long max_ns;    /* 가장 오래 걸린 기록 (나노초) */
    unsigned long lost;           /* 파일이 없거나 쓰기 오류로 잃은 기록 수 */
};

/* root = 세션 디렉토리들의 부모 (기본 /var/lib/mycontainer/sessions) */
void session_log_init(const char *root);

/*
 * cgroup_id 에 해당하는 세션 칸을 돌려준다.
 *   - 이미 열려 있으면 그 칸을 그대로 돌려준다 (대부분 이 경우)
 *   - 처음 보는 cgroup 이면 세션을 찾아서(by-cgroup 링크) 로그 파일을 열고 칸에 저장한다
 *   - 칸이 가득 차면 가장 오래 안 쓴 세션의 파일을 닫고 그 칸을 재사용한다
 * 항상 유효한 포인터를 돌려준다 (못 찾으면 _unattributed 세션).
 */
struct session *session_get(__u64 cgroup_id);

void session_write_event(struct session *s, const struct event_hdr *h, size_t len);
void session_write_verdict(struct session *s, const struct event_hdr *h, size_t len,
                           const struct verdict *v);
void session_write_action(struct session *s, const char *action, const char *reason);

const struct session_log_stats *session_log_get_stats(void);

/*
 * 열려 있는 모든 로그 파일을 닫는다.
 * 호출되는 때: (1) 로더가 정상 종료할 때 (2) session_log_init 이 다시 초기화하기 전에
 *              (3) 테스트가 끝나고 임시 폴더를 지우기 전에.
 * 세션 하나가 끝났다고 호출되지는 않는다. 로더는 컨테이너가 끝났는지 알 수 없기 때문이다.
 */
void session_log_close_all(void);

#endif /* SESSION_LOG_H */
