/*
 * session_log.c
 *
 * cgroup_id -> 세션 변환과 세션별 로그 파일 관리.
 * 세션이 무엇이고 by-cgroup 링크가 무엇인지는 session_log.h 의 설명을 먼저 읽을 것.
 *
 * ===== 이 파일을 읽는 순서 (호출 순서) =====
 *   session_get          진입점. 이벤트마다 호출된다
 *    └ resolve_session  처음 보는 cgroup 일 때만. by-cgroup 링크를 읽어 세션 ID 를 알아낸다
 *       ├ valid_session_id   읽은 값이 믿을 만한가 검사
 *       └ join2              경로 두 조각을 잘림 없이 이어 붙임
 *    └ open_append      로그 파일을 연다
 *   session_write_*     로그 한 줄을 기록한다 (fflush, 시간 측정 포함)
 *   session_log_close_all  종료 시 정리
 *
 * ===== 설계 메모 =====
 * - 로그 쓰기는 동기식이다 (수신 루프 안에서 직접 write). 로컬 파일 append 는 보통 마이크로초
 *   단위로 끝나지만, 디스크가 막히면 수신 루프도 멈춘다. 그래서 쓰기 시간을 재서 통계로 남긴다
 *   (5ms 를 넘는 기록 수와 최대 시간). 통계가 나쁘면 별도 스레드로 옮긴다.
 * - 쓰기에 실패해도 세션을 죽이지 않는다 ("경고 후 계속"). 대신 잃은 기록 수(lost)를 센다.
 *   로그가 비었는데 깨끗해 보이는 것을 막으려고 리포트에 이 숫자를 표시할 예정이다 (5주차).
 * - 로그 파일 권한은 0600 (root 만 읽고 쓴다).
 * - 알려진 한계: 캐시된 cgroup_id -> 세션 대응은 다시 확인하지 않는다. cgroup id 가 재사용되면
 *   오래된 세션에 잘못 기록될 수 있다 (64비트 커널에서 cgroup id 가 재사용되는지는 확인하지 못함).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "session_log.h"
#include "jsonl.h"

#define MAX_SESSIONS 64                    /* 동시에 열어 둘 세션 수 */
#define SLOW_WRITE_NS 5000000ULL           /* 5ms */

/*
 * ---------- 내부 상태 (전역 변수) ----------
 * g_root     : 세션 폴더들의 부모 경로 (예: /var/lib/mycontainer/sessions)
 * g_sessions : 세션 "칸(slot)" 64개짜리 고정 배열. 한 칸이 세션 하나의 런타임 상태이다.
 *              세션들을 배열에 저장해 두는 이유는, cgroup ID 로 세션을 찾는 결과(세션 ID, 열어 둔 로그 파일,
 *              종료 요청 여부)를 이벤트마다 다시 계산하지 않고 재사용하기 위해서이다.
 *              고정 크기 배열을 쓰는 이유: 동시에 도는 세션은 많아야 몇 개라 64칸을 순서대로 훑어도
 *              비용이 무시할 만하고, 메모리가 늘어나다 터지는 일도 없다 (malloc 이나 해시 테이블이 필요 없음).
 * g_tick     : 칸을 쓸 때마다 1 씩 올리는 번호. 칸의 last_used 에 적어서 "가장 오래 안 쓴 칸"을 알아낸다.
 * g_stats    : 로그 쓰기 통계.
 * static 이라 이 파일 밖에서는 이름이 보이지 않는다.
 */
static char g_root[PATH_MAX];
static struct session g_sessions[MAX_SESSIONS];
static unsigned long g_tick;               /* last_used 에 쓰는 증가 번호 */
static struct session_log_stats g_stats;

/* 단조 시계의 현재 시각(나노초). 쓰기에 걸린 시간을 재는 데 쓴다. */
static unsigned long long mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ULL + (unsigned long long)ts.tv_nsec;
}

/*
 * 세션 ID 로 써도 안전한 문자열인가.
 * 허용: 영문, 숫자, '.', '_', '-' 만. 길이 제한. '.' 으로 시작하는 이름(".", "..", 숨김)은 거부.
 *
 * 왜 검사하나: 링크의 내용으로 "경로를 조립"하기 때문이다. 링크는 root 가 만들지만, 예를 들어 내용이
 * ".." 이면 sessions 의 상위 폴더로 올라가 엉뚱한 곳에 로그를 쓰게 된다. 경로를 만드는 재료는
 * 출처가 믿을 만해도 한 번 더 걸러 둔다 (방어를 겹쳐 두는 습관).
 */
static int valid_session_id(const char *s)
{
    size_t n = strlen(s);
    if (n == 0 || n >= SESSION_ID_MAX || s[0] == '.')
        return 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok)
            return 0;
    }
    return 1;
}

/*
 * 경로 두 조각 a, b 를 "/" 로 이어서 out 에 만든다. 결과는 "a/b" 모양이다.
 *   예) join2(out, 4096, "/var/lib/mycontainer/sessions", "by-cgroup/309013")
 *       -> out = "/var/lib/mycontainer/sessions/by-cgroup/309013"
 * 경로가 out 보다 길어 잘리면 -1, 정상이면 0 을 돌려준다.
 *
 * 왜 snprintf 를 그냥 쓰지 않고 감쌌나:
 *   snprintf 는 버퍼가 작으면 에러 없이 "조용히 자른다". 대신 "자르지 않았다면 필요했을 길이"를 반환한다.
 *     char out[10]; int r = snprintf(out, 10, "%s/%s", "/tmp", "verylongname");
 *     -> out = "/tmp/very" (잘림), r = 17 (원래 필요했던 길이)
 *   r 이 버퍼 크기(10) 이상이면 잘린 것이다. 잘린 경로 "/tmp/very" 가 전혀 다른 파일을 가리킬 수 있으므로,
 *   보안 도구가 엉뚱한 곳에 쓰거나 읽지 않도록 잘림을 에러로 취급한다.
 */
static int join2(char *out, size_t n, const char *a, const char *b)
{
    int r = snprintf(out, n, "%s/%s", a, b);
    return (r < 0 || (size_t)r >= n) ? -1 : 0;
}

/*
 * 파일을 append(이어 쓰기) 모드, 권한 0600 으로 열어 FILE* 로 돌려준다. 실패하면 NULL.
 *   O_APPEND  : 쓸 때마다 항상 파일 끝에 붙인다 (기존 기록을 덮어쓰지 않음)
 *   O_CREAT   : 없으면 만든다
 *   O_CLOEXEC : 이 프로세스가 다른 프로그램을 실행(exec)해도 이 파일이 따라 넘어가지 않게 한다
 *   0600      : 만들 때의 권한. 소유자(root)만 읽고 쓴다 (로그를 다른 사용자가 못 읽게)
 * open() 은 정수 파일 번호를, fdopen() 은 그것을 fprintf 로 쓸 수 있는 FILE* 로 바꿔 준다.
 * 권한을 지정하려면 open() 이 필요하고, fopen() 은 권한을 지정할 수 없어서 둘을 함께 쓴다.
 */
static FILE *open_append(const char *path)
{
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0)
        return NULL;
    FILE *f = fdopen(fd, "a");
    if (!f)
        close(fd);
    return f;
}

/* 세션 칸 하나를 닫는다. 열려 있는 파일을 닫고(fclose 가 남은 버퍼도 내보냄) 칸을 비운다. */
static void close_session(struct session *s)
{
    if (s->events)   fclose(s->events);
    if (s->verdicts) fclose(s->verdicts);
    s->events = s->verdicts = NULL;
    s->in_use = 0;
}

/*
 * "이 cgroup_id 는 어느 세션인가"를 찾는다. 처음 보는 cgroup 일 때만 호출된다.
 * 한 줄 요약: by-cgroup/<cgroup_id> 링크를 읽어서 세션 ID 를 알아내고, 못 찾으면 _unattributed 로 처리한다.
 *
 * 실제 값으로 따라가 본다 (cgroup_id = 309013, 링크의 내용 = "../20261002-115607-1095185").
 *   1) rel  = "by-cgroup/309013"
 *      link = "<g_root>/by-cgroup/309013"            (join2 로 이어 붙임)
 *   2) readlink(link, target, ...)
 *        링크가 가리키는 경로 "문자열"을 읽는다. target = "../20261002-115607-1095185"
 *        open 이나 stat 과 달리 링크를 "따라가지 않고" 링크 항목의 내용 글자만 꺼낸다.
 *        링크가 없으면 -1 을 돌려준다.
 *        NUL(문자열 끝 표시)을 붙여 주지 않으므로 아래에서 직접 넣는다. 그 자리를 남기려고 크기를 sizeof - 1 로 준다.
 *   3) strrchr(target, '/') 로 마지막 '/' 를 찾아 그 다음부터를 쓴다 (strrchr 는 오른쪽 끝에서부터 찾는다)
 *        base = "20261002-115607-1095185"             (맨 앞의 "../" 는 버린다)
 *        '/' 가 없으면 target 전체가 base 이다.
 *   4) valid_session_id(base): 허용된 문자만 있는가
 *      join2 + stat + S_ISDIR : <g_root>/<base> 가 실제로 존재하는 "디렉토리"인가
 *        링크는 가리키는 곳이 없어도 만들어지므로(글자만 저장한다), 읽은 값을 믿지 않고 존재를 직접 확인한다.
 *        통과하면 id = base, 아니면 처음 정한 기본값 _unattributed 가 남는다.
 *   5) 결과를 세션 칸 s 에 저장
 *        s->id  = 세션 ID,   s->dir = "<g_root>/<세션ID>"
 *
 * 링크의 내용에서 실제로 쓰는 것은 마지막 조각(세션 ID) 뿐이다. 폴더 경로는 링크를 따라가서 얻는 것이 아니라
 * g_root 와 세션 ID 로 코드가 다시 조립한다. 링크는 "세션 ID 를 적어 둔 쪽지"로 쓰이는 셈이다.
 *
 * 결과 정리:
 *   링크가 있고 대상 폴더도 있다       -> 세션 ID
 *   링크가 없다 (readlink 가 -1)       -> _unattributed
 *   링크 내용에 이상한 문자나 ".." 이다 -> _unattributed
 *   링크는 있는데 폴더가 없다          -> _unattributed
 * 어느 경우에도 로그를 버리지 않는다.
 */
static void resolve_session(struct session *s, __u64 cgroup_id)
{
    char rel[48];                 /* "by-cgroup/<숫자>" 는 항상 이 안에 들어간다 */
    char link[PATH_MAX];
    char target[PATH_MAX];
    const char *id = UNATTRIBUTED_ID;

    /* rel 은 짧은 고정 크기라 잘릴 일이 없다: "by-cgroup/" 10자 + 64비트 숫자 최대 20자리 */
    snprintf(rel, sizeof(rel), "by-cgroup/%llu", (unsigned long long)cgroup_id);

    ssize_t n = -1;
    if (join2(link, sizeof(link), g_root, rel) == 0)
        n = readlink(link, target, sizeof(target) - 1);

    if (n > 0) {
        target[n] = '\0';                        /* readlink 는 끝 표시를 안 붙이므로 직접 넣는다 */
        const char *base = strrchr(target, '/');
        base = base ? base + 1 : target;         /* 조건 ? 참일 때 값 : 거짓일 때 값 (삼항 연산자) */
        if (valid_session_id(base)) {            /* 길이도 SESSION_ID_MAX 미만임이 보장됨 */
            char dir[PATH_MAX];
            struct stat st;
            if (join2(dir, sizeof(dir), g_root, base) == 0 &&
                stat(dir, &st) == 0 && S_ISDIR(st.st_mode))   /* S_ISDIR: 종류가 디렉토리인가 */
                id = base;
        }
    }

    /* id 는 검증된 문자열(또는 상수)이라 SESSION_ID_MAX 보다 짧다. 끝 표시(+1)까지 길이만큼 복사한다 */
    memcpy(s->id, id, strlen(id) + 1);

    /* 세션 디렉토리 경로. g_root 가 너무 길어 잘리면 빈 문자열로 두고, 파일 열기가 실패해 lost 로 센다 */
    if (join2(s->dir, sizeof(s->dir), g_root, s->id) != 0)
        s->dir[0] = '\0';

    /*
     * _unattributed 디렉토리는 처음 필요할 때 만든다 (이미 있으면 EEXIST 라 실패하지만 괜찮아서 무시).
     * 일반 세션의 폴더는 run_container.sh 가 미리 만들어 두지만 이 폴더는 아무도 만들지 않기 때문이다.
     */
    if (s->dir[0] != '\0' && strcmp(id, UNATTRIBUTED_ID) == 0)
        mkdir(s->dir, 0700);
}

/* 로그 시스템을 초기화한다. 이전에 열려 있던 파일이 있으면 먼저 닫고 상태를 모두 비운다. */
void session_log_init(const char *root)
{
    session_log_close_all();
    snprintf(g_root, sizeof(g_root), "%s", root);
    memset(g_sessions, 0, sizeof(g_sessions));
    memset(&g_stats, 0, sizeof(g_stats));
    g_tick = 0;
}

/*
 * cgroup_id 에 해당하는 세션 칸(slot)을 돌려준다.
 *
 * 칸을 고르는 과정:
 *   1) 표(g_sessions)를 훑으면서 같은 cgroup_id 가 이미 있는지 본다. 있으면 그 칸을 그대로 돌려준다.
 *      (이벤트 대부분이 여기서 끝난다. 파일 시스템을 다시 읽지 않는다)
 *      훑는 김에 "비어 있는 칸"과 "가장 오래 안 쓴 칸"도 기억해 둔다.
 *   2) 없으면 새로 열 칸을 정한다. 빈 칸이 있으면 그것을, 없으면 가장 오래 안 쓴 칸을 닫고 그 자리를 쓴다.
 *      (LRU: Least Recently Used. 밀려난 세션의 kill_requested 도 함께 사라지는 한계가 있다)
 *   3) 칸을 비우고(memset) 새 세션 정보를 채운 뒤 resolve_session 으로 세션을 찾고 로그 파일을 연다.
 *
 * 항상 유효한 칸을 돌려준다. 세션을 못 찾아도 _unattributed 세션이 돌아온다.
 */
struct session *session_get(__u64 cgroup_id)
{
    struct session *free_slot = NULL;
    struct session *lru = NULL;

    /* 1) 이미 열려 있으면 재사용. 동시에 빈 슬롯과 가장 오래 안 쓴 슬롯을 찾아 둔다 */
    for (int i = 0; i < MAX_SESSIONS; i++) {
        struct session *s = &g_sessions[i];
        if (s->in_use) {
            if (s->cgroup_id == cgroup_id) {
                s->last_used = ++g_tick;         /* 방금 썼다고 표시 (++ 를 앞에 붙이면 올린 뒤의 값을 씀) */
                return s;
            }
            if (!lru || s->last_used < lru->last_used)
                lru = s;                         /* last_used 가 가장 작은 칸 = 가장 오래 안 쓴 칸 */
        } else if (!free_slot) {
            free_slot = s;                       /* 처음 만난 빈 칸 */
        }
    }

    /* 2) 새로 열 슬롯을 정한다. 빈 슬롯이 없으면 가장 오래 안 쓴 것을 닫고 그 자리를 쓴다 */
    struct session *slot = free_slot ? free_slot : lru;
    if (slot->in_use)
        close_session(slot);

    memset(slot, 0, sizeof(*slot));
    slot->in_use = 1;
    slot->cgroup_id = cgroup_id;
    slot->last_used = ++g_tick;

    /* 3) 세션을 찾고 로그 파일을 연다. 열기에 실패하면 NULL 로 두고, 쓸 때 lost 로 센다 */
    resolve_session(slot, cgroup_id);

    char path[PATH_MAX];
    if (slot->dir[0] != '\0' && join2(path, sizeof(path), slot->dir, "events.jsonl") == 0)
        slot->events = open_append(path);
    if (slot->dir[0] != '\0' && join2(path, sizeof(path), slot->dir, "verdicts.jsonl") == 0)
        slot->verdicts = open_append(path);

    if (!slot->events || !slot->verdicts)
        fprintf(stderr, "[session_log] 로그 파일을 열지 못함 (%s): %s\n",
                slot->dir, strerror(errno));
    return slot;
}

/* 한 번의 쓰기에 걸린 시간을 통계에 반영. t0 는 쓰기를 시작하기 전에 잰 시각이다. */
static void account(unsigned long long t0)
{
    unsigned long long dt = mono_ns() - t0;
    g_stats.writes++;
    if (dt > g_stats.max_ns)
        g_stats.max_ns = dt;
    if (dt > SLOW_WRITE_NS)
        g_stats.slow_writes++;
}

/* 쓰기 후 오류 확인. 오류가 있으면 잃은 기록으로 세고 오류 상태를 지운다 */
static void check_error(FILE *f)
{
    if (ferror(f)) {
        g_stats.lost++;
        clearerr(f);
    }
}

/*
 * 이벤트 한 줄을 세션의 events.jsonl 에 기록한다.
 *
 * 왜 쓴 직후에 fflush 를 하나:
 *   fprintf 는 파일에 바로 쓰지 않고 프로그램 메모리의 버퍼에 모은다 (파일은 보통 4KB 가 찰 때까지).
 *
 *     fprintf -> [FILE 버퍼: 로더의 메모리] --fflush--> [커널 버퍼] --fsync--> 디스크
 *
 *   fflush 가 없으면 방금 쓴 한 줄이 로더의 메모리에만 있고 파일에는 없다. 그러면
 *     - 로더가 비정상 종료(kill -9, 크래시)하면 버퍼에 있던 마지막 기록들이 사라지고,
 *     - 사람이 cat 으로 열어 봐도 아직 안 보이고,
 *     - 테스트가 쓴 직후 파일을 읽으면 비어 있다.
 *   보안 로그에서는 가장 마지막 기록이 가장 중요한 증거일 때가 많다. 로더가 죽기 직전의 BLOCK 판정이
 *   버퍼에서 사라지면 안 되므로 기록마다 내보낸다.
 *
 *   fflush 는 "커널 버퍼까지"만 내보낸다. 로더 프로세스가 죽어도 기록은 남지만, 컴퓨터 전원이 나가거나
 *   커널이 죽으면 사라질 수 있다. fsync 는 디스크까지 확정하지만 매우 느려서 쓰지 않았다.
 *   대신 기록마다 시스콜이 한 번씩 나가는 비용이 생기므로 account 로 걸린 시간을 잰다.
 *
 * 파일 핸들이 NULL 이면 (열기에 실패했으면) 기록을 잃은 것으로 세고 돌아간다.
 */
void session_write_event(struct session *s, const struct event_hdr *h, size_t len)
{
    if (!s->events) {
        g_stats.lost++;
        return;
    }
    unsigned long long t0 = mono_ns();
    jsonl_write_event(s->events, s->id, h, len);
    fflush(s->events);                      /* 커널 버퍼까지는 바로 내보낸다 (fsync 는 아님) */
    check_error(s->events);
    account(t0);
}

/* 판정 한 줄을 세션의 verdicts.jsonl 에 기록한다. fflush 이유는 session_write_event 참고. */
void session_write_verdict(struct session *s, const struct event_hdr *h, size_t len,
                           const struct verdict *v)
{
    if (!s->verdicts) {
        g_stats.lost++;
        return;
    }
    unsigned long long t0 = mono_ns();
    jsonl_write_verdict(s->verdicts, s->id, h, len, v);
    fflush(s->verdicts);
    check_error(s->verdicts);
    account(t0);
}

/* 대응(action) 한 줄을 verdicts.jsonl 에 기록한다. 판정과 같은 파일에 남겨 "판정 -> 대응" 순서가 보이게 한다. */
void session_write_action(struct session *s, const char *action, const char *reason)
{
    if (!s->verdicts) {
        g_stats.lost++;
        return;
    }
    unsigned long long t0 = mono_ns();
    jsonl_write_action(s->verdicts, s->id, s->cgroup_id, action, reason);
    fflush(s->verdicts);
    check_error(s->verdicts);
    account(t0);
}

const struct session_log_stats *session_log_get_stats(void)
{
    return &g_stats;
}

/*
 * 열려 있는 모든 세션의 파일을 닫는다. 호출되는 때는 session_log.h 의 설명 참고.
 * 로더가 kill -9 나 크래시로 죽으면 이 함수는 호출되지 않는다. 그래도 매 기록마다 fflush 로
 * 커널에 넘겼기 때문에 이미 쓴 내용은 남고, 열려 있던 파일은 운영체제가 프로세스 종료 때 닫아 준다.
 */
void session_log_close_all(void)
{
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (g_sessions[i].in_use)
            close_session(&g_sessions[i]);
    }
}
