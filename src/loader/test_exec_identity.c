/*
 * test_exec_identity.c
 *
 * exec_identity 탐지기의 단위 테스트. 커널 없이 합성 EXEC_PATH 이벤트를 디스패처에 넣고
 * 판정의 수준, 탐지기 이름, 이유(규칙 표시 [M] / [L])를 검증한다.
 * 값은 VM 실측(docs/exec-identity-scenarios-w4.md 와 2단계 지시의 실측값)을 그대로 쓴다.
 *
 * test_write_exec_boundary.c 와 같이 실제 탐지기 파일 하나만 링크한다.
 * 탐지기는 생성자로 자동 등록되므로 dispatcher_reset_for_test() 를 부르면 안 된다 (등록이 지워진다).
 *
 * 빌드/실행: src/build.sh 가 만든 ./test_exec_identity (전부 통과하면 ALL PASSED, 종료 코드 0)
 */
#include <stdio.h>
#include <string.h>
#include "detector.h"
#include "dispatcher.h"

static int failures;

#define CHECK(cond, msg) do { \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { printf("  FAIL  %s\n", msg); failures++; } \
} while (0)

/* sink 가 받은 판정을 기록한다 */
static int sink_count;                 /* 받은 판정 수 */
static enum verdict_level last_level;  /* 마지막 판정 수준 */
static char last_detector[64];         /* 마지막 판정의 탐지기 이름 */
static char last_reason[128];          /* 마지막 판정의 이유 (복사본) */
static int last_reason_nul;            /* 원본 reason 128바이트 안에 NUL 이 있었나 */

static void test_sink(const struct event_hdr *h, size_t len,
                      const struct verdict *v, void *ctx)
{
    (void)h; (void)len; (void)ctx;
    sink_count++;
    last_level = v->level;
    snprintf(last_detector, sizeof(last_detector), "%s", v->detector);
    /* 복사 전에 원본이 128바이트 안에서 끝나는지 본다 (snprintf 복사는 원본이 길어도 잘라서 감춘다) */
    last_reason_nul = memchr(v->reason, '\0', sizeof(v->reason)) != NULL;
    snprintf(last_reason, sizeof(last_reason), "%.*s", (int)sizeof(v->reason), v->reason);
}

static void reset_sink(void)
{
    sink_count = 0;
    last_level = (enum verdict_level)0;
    last_detector[0] = '\0';
    last_reason[0] = '\0';
    last_reason_nul = 0;
}

/*
 * 합성 EXEC_PATH. filename 은 요청 이름, 나머지 셋은 최종·부모·조부모 dentry 이름이다.
 * memset 으로 남은 영역을 0 으로 채운다 (각 칸은 NUL 로 끝난다. 꽉 찬 칸은 시험에서 따로 덮어쓴다).
 */
static struct evt_exec_path make_ep(const char *filename, const char *final_name,
                                    const char *parent, const char *grandparent)
{
    struct evt_exec_path e;
    memset(&e, 0, sizeof(e));
    e.hdr.kind = EVT_EXEC_PATH;
    e.hdr.pid = 300;
    e.hdr.cgroup_id = 7;
    e.hdr.ts_ns = 6000;
    e.hdr.payload_len = sizeof(e) - sizeof(e.hdr);
    snprintf(e.filename, sizeof(e.filename), "%s", filename);
    snprintf(e.final_name, sizeof(e.final_name), "%s", final_name);
    snprintf(e.parent_name, sizeof(e.parent_name), "%s", parent);
    snprintf(e.grandparent_name, sizeof(e.grandparent_name), "%s", grandparent);
    return e;
}

/* 이벤트 하나를 디스패처에 넣는다 (sink 를 비우고) */
static void run(const struct evt_exec_path *e, size_t len)
{
    reset_sink();
    dispatch_event(e, len);
}

/*
 * reason 의 계약 문구 (docs/log-schema.md 의 "reason 의 계약"). 탐지기 소스에서 가져오지 않고 여기 따로 적는다.
 * is_suspect 는 규칙 표시가 이유 어디에 있어도 맞으므로, 맨 앞부터의 문구는 starts_with 로 따로 본다.
 */
#define PREFIX_M "[M] 메모리에서 실행(memfd): 요청 "
#define PREFIX_L "[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 "

/* s 가 접두어 p 로 시작하는가 (앞에서부터 문구 전체를 맞춘다) */
static int starts_with(const char *s, const char *p)
{
    return strncmp(s, p, strlen(p)) == 0;
}

/* 판정이 정확히 하나이고 exec_identity 의 SUSPECT 이며 이유에 tag 가 있는가 */
static int is_suspect(const char *tag)
{
    return sink_count == 1 && last_level == V_SUSPECT
        && strcmp(last_detector, "exec_identity") == 0
        && strstr(last_reason, tag) != NULL;
}

/* ===================== 테스트 1: 규칙 M ===================== */
static void test_rule_m(void)
{
    printf("[규칙 M: 최종 이름이 memfd: 로 시작]\n");
    struct evt_exec_path e;

    e = make_ep("/proc/self/fd/3", "memfd:x", "memfd:x", "memfd:x");
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]"), "M(a) 경로 문자열 실행 /proc/self/fd/3 -> SUSPECT [M]");
    CHECK(strstr(last_reason, "요청 /proc/self/fd/3") && strstr(last_reason, "실제 memfd:x"),
          "M(a) 이유에 요청 이름과 실제 이름이 들어감");
    CHECK(starts_with(last_reason, PREFIX_M), "M(a) 이유는 '[M] 메모리에서 실행(memfd): 요청 ' 로 시작");
    CHECK(strcmp(last_reason, "[M] 메모리에서 실행(memfd): 요청 /proc/self/fd/3, 실제 memfd:x") == 0,
          "M(a) 이유가 '[M] 메모리에서 실행(memfd): 요청 /proc/self/fd/3, 실제 memfd:x' 와 정확히 같음");

    e = make_ep("/dev/fd/3", "memfd:x", "memfd:x", "memfd:x");
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]"), "M(b) fd 직접 실행 /dev/fd/3 -> SUSPECT [M]");

    e = make_ep("/tmp/x", "memfd:x", "memfd:x", "memfd:x");
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]") && strstr(last_reason, "요청 /tmp/x"), "M(c) 링크로 감춘 memfd /tmp/x -> SUSPECT [M]");

    e = make_ep("/proc/self/fd/3", "memfd:", "memfd:", "memfd:");
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]"), "M(d) 콜론 뒤가 빈 memfd: 도 접두어가 맞으니 SUSPECT [M]");

    e = make_ep("/proc/self/fd/3", "memfd", "bin", "usr");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "M(e) 콜론 없는 memfd -> 판정 없음");

    e = make_ep("/proc/self/fd/3", "xmemfd:x", "bin", "usr");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "M(f) 앞 글자가 다른 xmemfd:x -> 판정 없음");

    /* 세 이름 칸을 모두 NUL 없이 꽉 채운다. 칸 밖을 읽으면 구조체 끝을 넘는다 (ASan 빌드에서 잡힘) */
    e = make_ep("/proc/self/fd/3", "", "", "");
    memset(e.final_name, 'A', MAX_DNAME);
    memcpy(e.final_name, "memfd:", 6);
    memset(e.parent_name, 'B', MAX_DNAME);
    memset(e.grandparent_name, 'C', MAX_DNAME);
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]") && strstr(last_reason, "memfd:AAAA") && !strchr(last_reason, 'B'),
          "M(g) NUL 없는 64바이트 memfd:AAA... 도 칸 안에서만 읽고 SUSPECT [M]");

    e = make_ep("/proc/self/fd/3", "", "", "");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "M(h) 최종 이름이 빈 문자열 -> 판정 없음");
}

/* ===================== 테스트 2: 규칙 L ===================== */
static void test_rule_l(void)
{
    printf("[규칙 L: 요청 이름과 다른 실제 파일이 임시 위치 바로 아래]\n");
    struct evt_exec_path e;
    char longreq[MAX_FILENAME];    /* 긴 요청 이름 */

    e = make_ep("/tmp/bin/ls", "payload", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]"), "L(a) /tmp/bin/ls -> /tmp/payload: SUSPECT [L]");
    CHECK(starts_with(last_reason, PREFIX_L), "L(a) 이유는 '[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 ' 로 시작");
    CHECK(strcmp(last_reason, "[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 ls, 실제 payload (위치 /tmp)") == 0,
          "L(a) 이유가 '요청 ls, 실제 payload (위치 /tmp)' 문구와 정확히 같음");
    CHECK(strstr(last_reason, "요청 ls,") && !strstr(last_reason, "/tmp/bin"),
          "L(a) 이유의 요청 이름은 basename(ls)이고 경로 /tmp/bin 은 없음");

    e = make_ep("/var/tmp/ls", "p", "tmp", "var");
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]") && strstr(last_reason, "(위치 /var/tmp)"), "L(b) /var/tmp 아래 다른 이름 -> SUSPECT [L] (위치 /var/tmp)");
    CHECK(strcmp(last_reason, "[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 ls, 실제 p (위치 /var/tmp)") == 0,
          "L(b) 이유가 '요청 ls, 실제 p (위치 /var/tmp)' 문구와 정확히 같음");

    e = make_ep("./hello", "hello", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(c) 같은 이름 ./hello -> hello -> 판정 없음");

    e = make_ep("/tmp/venv/bin/python", "python3.14", "bin", "usr");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(d) venv 링크가 시스템 영역 python3.14 로 -> 판정 없음");

    e = make_ep("/bin/ls", "busybox", "bin", "/");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(e) busybox /bin/ls -> 판정 없음");

    e = make_ep("/tmp/s.sh", "dash", "bin", "usr");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(f) 셔뱅 둘째 호출 (인터프리터 dash, /usr/bin) -> 판정 없음");

    e = make_ep("/tmp/s.sh", "evil", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]"), "L(g) 셔뱅 인터프리터가 /tmp/evil -> SUSPECT [L]");

    /* 80자 이름: 커널 칸에서 최종 이름이 앞 63자로 잘린다 (VM 실측) */
    memcpy(longreq, "/tmp/", 5);
    memset(longreq + 5, 'a', 80);
    longreq[85] = '\0';
    e = make_ep(longreq, "", "tmp", "/");
    memset(e.final_name, 'a', MAX_DNAME - 1);
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(h) 80자 이름이 63자로 잘려도 앞 63자가 같으면 판정 없음");

    memset(longreq + 5, 'b', 80);
    e = make_ep(longreq, "", "tmp", "/");
    memset(e.final_name, 'a', MAX_DNAME - 1);
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]"), "L(i) 80자 이름의 앞 63자가 다르면 SUSPECT [L]");

    e = make_ep("/tmp/sub/y", "x", "sub", "tmp");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(j) /tmp/sub/x 는 (x, sub, tmp)라 못 가림 -> 판정 없음 (알려진 한계)");

    e = make_ep("/home/tmp/y", "x", "tmp", "home");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(k) /home/tmp 는 임시 위치 목록 밖 -> 판정 없음");

    e = make_ep("/tmp/", "payload", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(l) 요청 basename 이 빈 /tmp/ -> 판정 없음");

    e = make_ep("", "payload", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(l) 요청 이름이 빈 문자열 -> 판정 없음");

    e = make_ep("ls", "payload", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]"), "L(m) '/' 없는 요청 이름 ls -> /tmp/payload: SUSPECT [L]");

    e = make_ep("/var/lib/ls", "p", "lib", "var");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(n) 조부모가 var 여도 부모가 tmp 가 아니면 (/var/lib) 판정 없음");

    e = make_ep("/lib/ls", "p", "lib", "/");
    run(&e, sizeof(e));
    CHECK(sink_count == 0, "L(o) 조부모가 / 여도 부모가 tmp 가 아니면 (/lib) 판정 없음");
}

/* ===================== 테스트 3: 이유 문자열 길이 ===================== */
static void test_reason_len(void)
{
    printf("[이유 문자열은 128바이트 안에서 NUL 로 끝남]\n");
    struct evt_exec_path e;

    /* 255바이트 요청 이름 + NUL (규칙 M) */
    e = make_ep("", "memfd:x", "memfd:x", "memfd:x");
    memset(e.filename, 'Z', MAX_FILENAME - 1);
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]") && last_reason_nul, "M: 255바이트 요청 이름에도 이유가 128바이트 안에서 끝남");

    /* NUL 없이 256바이트 꽉 찬 요청 이름 (규칙 L, basename 이 256바이트) */
    e = make_ep("", "payload", "tmp", "/");
    memset(e.filename, 'Z', MAX_FILENAME);
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]") && last_reason_nul, "L: NUL 없는 256바이트 요청 이름에도 이유가 128바이트 안에서 끝남");
    CHECK(strstr(last_reason, "요청 ZZZZZZZZZZZZZZZZZZZ~, 실제") != NULL,
          "L: 긴 basename 은 앞 19바이트와 잘림 표시 ~ 로 보임");

    /* 가장 긴 경우: 잘린 basename(20) + 최종 이름 64바이트 꽉 참(15만 보임) + 위치 /var/tmp(8) = 정확히 127바이트 */
    e = make_ep("", "", "tmp", "var");
    memset(e.filename, 'Z', MAX_FILENAME);
    memset(e.final_name, 'Y', MAX_DNAME);
    run(&e, sizeof(e));
    CHECK(is_suspect("[L]") && last_reason_nul && strlen(last_reason) == 127
          && strstr(last_reason, "(위치 /var/tmp)") != NULL,
          "L: 가장 긴 이유(127바이트)도 문구 끝 (위치 /var/tmp)까지 잘리지 않음");
}

/* ===================== 테스트 4: 무시해야 하는 입력 ===================== */
static void test_ignored(void)
{
    printf("[무시해야 하는 입력]\n");
    struct evt_exec_path e = make_ep("/proc/self/fd/3", "memfd:x", "memfd:x", "memfd:x");

    /* 1바이트 짧다: 디스패처는 헤더 길이만 보므로 탐지기까지 오고, 탐지기가 -1(오류)을 돌려준다 */
    run(&e, sizeof(e) - 1);
    CHECK(sink_count == 0, "구조체보다 1바이트 짧은 EXEC_PATH -> 판정 없음");

    run(&e, sizeof(struct event_hdr));
    CHECK(sink_count == 0, "헤더 길이뿐인 EXEC_PATH -> 판정 없음");

    /* 오류 두 번 뒤 정상 입력: 연속 오류가 초기화되고 탐지기는 꺼지지 않았다 */
    run(&e, sizeof(e));
    CHECK(is_suspect("[M]"), "짧은 입력 두 번 뒤에도 정상 입력은 판정됨 (탐지기가 꺼지지 않음)");

    /* EXEC 이벤트: 이 탐지기는 EXEC_PATH 만 구독한다 */
    struct evt_exec x;
    memset(&x, 0, sizeof(x));
    x.hdr.kind = EVT_EXEC;
    x.hdr.cgroup_id = 7;
    snprintf(x.filename, sizeof(x.filename), "/proc/self/fd/3");
    reset_sink();
    dispatch_event(&x, sizeof(x));
    CHECK(sink_count == 0, "EXEC 이벤트에는 반응하지 않음");

    /* TAG_HIT 이벤트도 마찬가지 */
    struct evt_tag_hit t;
    memset(&t, 0, sizeof(t));
    t.hdr.kind = EVT_TAG_HIT;
    t.hdr.cgroup_id = 7;
    snprintf(t.filename, sizeof(t.filename), "/tmp/bin/ls");
    reset_sink();
    dispatch_event(&t, sizeof(t));
    CHECK(sink_count == 0, "TAG_HIT 이벤트에는 반응하지 않음");
}

/* ===================== 테스트 5: 한 이벤트에 판정 하나 ===================== */
static void test_single(void)
{
    printf("[한 이벤트에 판정은 최대 하나, 규칙 M 이 먼저]\n");
    /* memfd 이면서 부모·조부모가 /tmp 이고 이름도 다르다 (실제로는 생기지 않는 조합, 순서를 고정하는 시험) */
    struct evt_exec_path e = make_ep("/tmp/ls", "memfd:x", "tmp", "/");
    run(&e, sizeof(e));
    CHECK(sink_count == 1, "두 규칙에 모두 걸릴 만한 이벤트에도 판정은 하나");
    CHECK(is_suspect("[M]") && !strstr(last_reason, "[L]"), "그 판정은 규칙 M");
}

int main(void)
{
    dispatcher_set_sink(test_sink, NULL);   /* 탐지기는 생성자가 이미 등록했다 */
    test_rule_m();
    test_rule_l();
    test_reason_len();
    test_ignored();
    test_single();

    printf("\n%s (실패 %d)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
