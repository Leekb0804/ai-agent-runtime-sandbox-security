/*
 * test_verdict_handler.c
 *
 * ===== 이 파일의 역할 =====
 * 커널 없이 판정 처리(verdict_handler)와 세션 로그(session_log)를 검증한다.
 * 임시 디렉토리에 가짜 세션 구조를 만들어 놓고, 가짜 판정을 handle_verdict 에 직접 넣어서
 * 로그 파일에 기대한 내용이 남는지 읽어서 확인한다.
 * (테스트가 돌아가는 원리는 test_dispatcher.c 의 설명과 같다: 일반 C 프로그램이 입력을 만들어 넣고 결과를 센다)
 *
 * ===== 테스트가 만드는 가짜 세션 구조 =====
 *   <tmp>/by-cgroup/1234 -> ../sess-A        정상 세션. 링크의 내용(경로)이 "../sess-A" 이고 폴더가 실제로 있음
 *   <tmp>/sess-A/                            세션 디렉토리
 *   <tmp>/by-cgroup/777  -> ../etc           링크는 있지만 가리키는 폴더가 없음 (끊어진 링크)
 *   <tmp>/by-cgroup/778  -> "../bad id"      허용되지 않는 문자(공백)
 *   <tmp>/by-cgroup/779  -> ..               상위 폴더로 올라가는 경로 조작 시도
 *
 * 이 링크들은 실제로는 run_container.sh 의 "ln -sfn" 이 만드는 것이고(session_log.h 참고),
 * 여기서는 C 의 symlink() 로 흉내 낸다.
 *
 * 빌드/실행: src/build.sh 가 만든 ./test_verdict_handler
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <sys/stat.h>
#include "detector.h"
#include "session_log.h"
#include "verdict_handler.h"

/* 실패한 검사 개수. main 이 끝날 때 0 이 아니면 종료 코드를 1 로 낸다. */
static int failures;

/*
 * 검사 매크로. 조건이 참이면 PASS, 거짓이면 FAIL 을 출력하고 실패 개수를 올린다.
 * do { ... } while (0) 는 매크로를 함수 호출처럼 한 문장으로 안전하게 쓰기 위한 관용구이다.
 */
#define CHECK(cond, msg) do { \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { printf("  FAIL  %s\n", msg); failures++; } \
} while (0)

/* 이번 테스트의 임시 세션 루트 경로 (setup 에서 정함) */
static char root[PATH_MAX];

/*
 * 파일 전체를 문자열로 읽는다. 없으면 NULL. 호출한 쪽이 free 한다.
 * 테스트가 "로그 파일에 무엇이 기록됐는지" 읽어서 확인하려는 도우미이다.
 * (파일 끝으로 가서 크기를 재고(fseek, ftell), 처음으로 돌아와서(rewind) 그 크기만큼 읽는다)
 */
static char *slurp(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    char *buf = malloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    buf[got] = '\0';
    fclose(f);
    return buf;
}

/* hay 안에 needle 이 몇 번 나오는지 센다. strstr 로 찾고 찾은 길이만큼 건너뛰며 반복한다. */
static int count_sub(const char *hay, const char *needle)
{
    int n = 0;
    size_t len = strlen(needle);
    for (const char *p = hay; (p = strstr(p, needle)) != NULL; p += len)
        n++;
    return n;
}

/* 줄 수 = 줄바꿈 문자 개수. JSON Lines 는 레코드 하나가 한 줄이라서 줄 수가 곧 레코드 수이다. */
static int count_lines(const char *s) { return count_sub(s, "\n"); }

/* 커널이 ring buffer 에 써 주는 EXEC 이벤트를 테스트가 손으로 채운다 (구조체를 0 으로 먼저 채운 뒤 값을 넣음) */
static void make_exec(struct evt_exec *e, __u64 cg, const char *filename)
{
    memset(e, 0, sizeof(*e));
    e->hdr.kind = EVT_EXEC;
    e->hdr.pid = 4242;
    e->hdr.cgroup_id = cg;
    e->hdr.ts_ns = 1000;
    e->hdr.payload_len = sizeof(e->filename);
    snprintf(e->filename, sizeof(e->filename), "%s", filename);
}

/*
 * 가짜 판정 하나를 handle_verdict 에 넣는다. 실제로는 디스패처가 하는 일을 테스트가 대신한다.
 * 마지막 인자 ctx 로 NULL 을 넘기는 이유: 화면 출력(echo)이 필요 없기 때문이다. 로더는 stdout 을 넘긴다.
 */
static void send_verdict(__u64 cg, const char *filename, enum verdict_level lvl,
                         const char *detector, const char *reason)
{
    struct evt_exec e;
    struct verdict v;
    make_exec(&e, cg, filename);
    memset(&v, 0, sizeof(v));
    v.level = lvl;
    v.detector = detector;
    snprintf(v.reason, sizeof(v.reason), "%s", reason);
    handle_verdict(&e.hdr, sizeof(e), &v, NULL);      /* ctx=NULL: 화면 출력 없음 */
}

/* root 아래의 상대 경로를 전체 경로로 만든다 */
static void path_of(char *out, size_t n, const char *rel)
{
    snprintf(out, n, "%s/%s", root, rel);
}

/*
 * 테스트 준비: 임시 폴더를 만들고 가짜 세션 구조를 만든다.
 * mkdtemp 는 이름의 XXXXXX 를 무작위 문자로 바꿔 "아직 없는" 임시 폴더를 만들어 준다 (테스트끼리 겹치지 않음).
 *
 * symlink(대상, 링크의 위치) 의 인자 순서에 주의:
 *   첫 번째 인자가 링크의 "내용"(가리킬 경로 문자열), 두 번째가 링크가 "만들어질 위치"이다.
 *   ln -s 와 같은 순서이고, 호출 한 번에 위치에 내용이 채워진 링크가 생긴다 (별도의 write 가 없음).
 * 상대 경로 "../sess-A" 는 링크가 놓인 폴더(by-cgroup)를 기준으로 해석된다.
 * 링크는 가리키는 곳이 실제로 있는지 확인하지 않고 글자만 저장하므로, 777 처럼 폴더가 없어도 만들어진다.
 */
static void setup(void)
{
    char tmpl[] = "/tmp/myc_test_XXXXXX";
    if (!mkdtemp(tmpl)) { perror("mkdtemp"); exit(2); }
    snprintf(root, sizeof(root), "%s", tmpl);

    char p[PATH_MAX];
    path_of(p, sizeof(p), "by-cgroup"); mkdir(p, 0755);
    path_of(p, sizeof(p), "sess-A");    mkdir(p, 0755);

    path_of(p, sizeof(p), "by-cgroup/1234"); symlink("../sess-A", p);   /* 정상 */
    path_of(p, sizeof(p), "by-cgroup/777");  symlink("../etc", p);      /* 폴더가 없는 링크 */
    path_of(p, sizeof(p), "by-cgroup/778");  symlink("../bad id", p);   /* 공백이 든 ID */
    path_of(p, sizeof(p), "by-cgroup/779");  symlink("..", p);          /* 경로 조작 */

    session_log_init(root);
}

/*
 * 테스트 정리. 열려 있는 로그 파일을 먼저 닫고(session_log_close_all) 임시 폴더를 지운다.
 * 닫지 않고 지우면 열린 파일이 남아 있는 채로 폴더가 사라진다. root 는 우리가 mkdtemp 로 만든 경로이다.
 */
static void teardown(void)
{
    session_log_close_all();
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root);   /* root 는 우리가 mkdtemp 로 만든 경로 */
    if (system(cmd) != 0) fprintf(stderr, "임시 디렉토리 삭제 실패: %s\n", root);
}

/* 테스트 1: SUSPECT 는 기록만 하고 대응(action)을 일으키지 않는다 */
static void test_suspect_only_logged(void)
{
    printf("[SUSPECT 는 기록만]\n");
    char p[PATH_MAX];
    send_verdict(1234, "/bin/ls", V_SUSPECT, "dummy_suspect", "dummy");

    path_of(p, sizeof(p), "sess-A/verdicts.jsonl");
    char *log = slurp(p);
    CHECK(log != NULL, "세션 디렉토리에 verdicts.jsonl 이 생김");
    if (!log) return;
    CHECK(strstr(log, "\"session\":\"sess-A\"") != NULL, "cgroup_id 가 세션 sess-A 로 변환됨");
    CHECK(strstr(log, "\"level\":\"SUSPECT\"") != NULL, "SUSPECT 판정이 기록됨");
    CHECK(count_sub(log, "\"type\":\"action\"") == 0, "SUSPECT 는 대응(action)을 일으키지 않음");
    free(log);
}

/*
 * 테스트 2: BLOCK 이 두 번 와도 판정은 둘 다 기록하지만 종료 요청(action)은 한 번만 낸다 (멱등성).
 * 기대하는 로그: SUSPECT 1줄(테스트 1) + BLOCK 2줄 + action 1줄 = 4줄
 */
static void test_block_kills_once(void)
{
    printf("[BLOCK 은 종료 요청을 한 번만]\n");
    char p[PATH_MAX];
    send_verdict(1234, "/tmp/trigger", V_BLOCK, "dummy_block", "첫 번째 BLOCK");
    send_verdict(1234, "/tmp/trigger", V_BLOCK, "other_detector", "두 번째 BLOCK");

    path_of(p, sizeof(p), "sess-A/verdicts.jsonl");
    char *log = slurp(p);
    if (!log) { CHECK(0, "로그를 읽을 수 있음"); return; }
    CHECK(count_sub(log, "\"level\":\"BLOCK\"") == 2, "BLOCK 판정은 둘 다 기록됨");
    CHECK(count_sub(log, "\"type\":\"action\"") == 1, "종료 요청(action)은 한 번만");
    CHECK(strstr(log, "\"action\":\"would_kill\"") != NULL, "스텁이 would_kill 을 기록함");
    CHECK(count_lines(log) == 4, "SUSPECT 1 + BLOCK 2 + action 1 = 4줄");
    free(log);
}

/*
 * 테스트 3: 세션을 못 찾는 경우 로그를 버리지 않고 _unattributed 에 기록한다.
 *   9999 : 링크가 아예 없음
 *   777  : 링크는 있지만 가리키는 폴더가 없음. readlink 는 성공해도 폴더 존재 확인(stat)에서 걸러진다
 *   778  : 공백 같은 허용되지 않는 문자
 *   779  : ".." 경로 조작
 */
static void test_unattributed(void)
{
    printf("[세션을 못 찾으면 버리지 않고 _unattributed]\n");
    char p[PATH_MAX];

    send_verdict(9999, "/bin/ls", V_SUSPECT, "dummy_suspect", "dummy");
    path_of(p, sizeof(p), "_unattributed/verdicts.jsonl");
    char *log = slurp(p);
    CHECK(log != NULL, "링크가 없는 cgroup 은 _unattributed 에 기록됨");
    if (log) {
        CHECK(strstr(log, "\"cgroup_id\":9999") != NULL, "이벤트에 cgroup_id 가 남아 추적 가능");
        free(log);
    }

    CHECK(strcmp(session_get(777)->id, UNATTRIBUTED_ID) == 0, "링크 대상 디렉토리가 없으면 _unattributed");
    CHECK(strcmp(session_get(778)->id, UNATTRIBUTED_ID) == 0, "허용되지 않는 문자가 든 ID 는 거부");
    CHECK(strcmp(session_get(779)->id, UNATTRIBUTED_ID) == 0, "'..' 같은 경로 조작은 거부");
}

/*
 * 테스트 4: 로그 위조 시도. 파일 이름 안에 따옴표, 줄바꿈, 가짜 action 레코드를 심어도
 * 로그는 한 줄만 늘어나고 가짜 레코드는 진짜 레코드가 되지 못해야 한다 (이스케이프 덕분).
 */
static void test_log_forgery(void)
{
    printf("[로그 위조 시도]\n");
    char p[PATH_MAX];
    path_of(p, sizeof(p), "sess-A/verdicts.jsonl");

    char *before = slurp(p);
    int lines_before = count_lines(before);
    int actions_before = count_sub(before, "\"type\":\"action\"");
    free(before);

    /* 파일 이름 안에 가짜 action 줄을 심는다 */
    send_verdict(1234, "x\"}\n{\"type\":\"action\",\"action\":\"fake\"",
                 V_SUSPECT, "dummy_suspect", "forgery");

    char *after = slurp(p);
    CHECK(count_lines(after) == lines_before + 1, "위조 시도가 한 줄만 추가함 (줄이 갈라지지 않음)");
    CHECK(strstr(after, "\\\"type\\\":\\\"action\\\"") != NULL,
          "가짜 action 은 이스케이프된 문자열로만 남음");
    CHECK(count_sub(after, "\"type\":\"action\"") == actions_before, "진짜 action 레코드 수는 그대로");
    free(after);
}

/* 테스트 5: 로그 파일 권한이 0600 (소유자만 읽고 쓰기). 8진수 0777 로 권한 비트만 뽑아 비교한다. */
static void test_file_mode(void)
{
    printf("[파일 권한]\n");
    char p[PATH_MAX];
    struct stat st;
    path_of(p, sizeof(p), "sess-A/verdicts.jsonl");
    CHECK(stat(p, &st) == 0 && (st.st_mode & 0777) == 0600, "로그 파일 권한이 0600");
}

/*
 * 테스트 6: 세션 칸(64개)이 가득 차도 동작한다.
 * 칸보다 많은 cgroup 을 열면 가장 오래 안 쓴 세션이 밀려나며 그 파일이 닫힌다.
 * 밀려난 세션(1234)에 다시 기록이 오면 칸이 새로 열리고, 같은 파일에 이어서 쓰여야 한다 (append).
 */
static void test_eviction(void)
{
    printf("[슬롯이 가득 차도 동작]\n");
    /* 슬롯(64)보다 많은 cgroup 을 연다 -> 가장 오래 안 쓴 세션이 밀려나며 파일이 닫힌다 */
    for (__u64 cg = 20000; cg < 20100; cg++)
        session_get(cg);

    /* 밀려났던 세션도 다시 열려서 정상 기록된다 */
    send_verdict(1234, "/bin/ls", V_SUSPECT, "dummy_suspect", "after eviction");
    CHECK(strcmp(session_get(1234)->id, "sess-A") == 0, "밀려났다가 다시 열려도 같은 세션으로 변환됨");

    char p[PATH_MAX];
    path_of(p, sizeof(p), "sess-A/verdicts.jsonl");
    char *log = slurp(p);
    CHECK(log && strstr(log, "after eviction") != NULL, "다시 연 뒤의 기록이 같은 파일에 이어서 쓰임 (append)");
    free(log);

    CHECK(session_log_get_stats()->lost == 0, "기록을 잃지 않음 (lost == 0)");
}

int main(void)
{
    setup();

    test_suspect_only_logged();
    test_block_kills_once();
    test_unattributed();
    test_log_forgery();
    test_file_mode();
    test_eviction();

    teardown();
    printf("\n%s (실패 %d)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;      /* 종료 코드: 성공 0, 실패 1 */
}
