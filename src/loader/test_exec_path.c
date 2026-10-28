/*
 * test_exec_path.c
 *
 * EVT_EXEC_PATH 이벤트의 단위 테스트. 커널 없이 합성 이벤트를 jsonl_write_event 에 넣고
 * events.jsonl 한 줄의 "event" 객체를 글자 단위로 검증한다.
 * 함께 기존 이벤트 형식(구조체 크기와 필드 위치, EXEC/TAG_HIT 의 출력)이 바뀌지 않았음을 고정한다.
 *
 * 빌드/실행: src/build.sh 가 만든 ./test_exec_path (전부 통과하면 ALL PASSED, 종료 코드 0)
 */
#define _GNU_SOURCE               /* open_memstream 을 쓰기 위한 표준 확장 활성화 (헤더 include 보다 먼저) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>               /* offsetof */
#include "jsonl.h"

/*
 * 하위 호환 고정: 기존 구조체의 크기와 필드 위치, 기존 enum 값이 바뀌면 컴파일이 실패한다.
 * event.h 에 넣지 않고 이 테스트에 둔다 (event.h 는 BPF 쪽과 공유하는 형식 정의만 둔다).
 */
_Static_assert(sizeof(struct event_hdr) == 32, "event_hdr 크기가 바뀌었다");
_Static_assert(offsetof(struct event_hdr, kind) == 0, "event_hdr.kind 위치");
_Static_assert(offsetof(struct event_hdr, pid) == 4, "event_hdr.pid 위치");
_Static_assert(offsetof(struct event_hdr, cgroup_id) == 8, "event_hdr.cgroup_id 위치");
_Static_assert(offsetof(struct event_hdr, ts_ns) == 16, "event_hdr.ts_ns 위치");
_Static_assert(offsetof(struct event_hdr, payload_len) == 24, "event_hdr.payload_len 위치");
_Static_assert(offsetof(struct event_hdr, _pad) == 28, "event_hdr._pad 위치");
_Static_assert(sizeof(struct evt_exec) == 288, "evt_exec 크기가 바뀌었다");
_Static_assert(offsetof(struct evt_exec, filename) == 32, "evt_exec.filename 위치");
_Static_assert(sizeof(struct evt_tag_hit) == 328, "evt_tag_hit 크기가 바뀌었다");
_Static_assert(offsetof(struct evt_tag_hit, exec_cgroup_id) == 32, "evt_tag_hit.exec_cgroup_id 위치");
_Static_assert(offsetof(struct evt_tag_hit, tag_ts_ns) == 40, "evt_tag_hit.tag_ts_ns 위치");
_Static_assert(offsetof(struct evt_tag_hit, tag_write_count) == 48, "evt_tag_hit.tag_write_count 위치");
_Static_assert(offsetof(struct evt_tag_hit, dev) == 56, "evt_tag_hit.dev 위치");
_Static_assert(offsetof(struct evt_tag_hit, _pad) == 60, "evt_tag_hit._pad 위치");
_Static_assert(offsetof(struct evt_tag_hit, ino) == 64, "evt_tag_hit.ino 위치");
_Static_assert(offsetof(struct evt_tag_hit, filename) == 72, "evt_tag_hit.filename 위치");
_Static_assert(EVT_EXEC == 1 && EVT_WRITE == 2 && EVT_OPEN == 3 && EVT_DNS == 4 && EVT_TAG_HIT == 5,
               "기존 이벤트 종류 번호가 바뀌었다");
_Static_assert(DROP_EXEC == 0 && DROP_TAG_HIT == 1, "기존 드롭 칸 번호가 바뀌었다");
/* 새 종류의 앞부분도 다른 종류와 같은 배치(헤더 뒤 바로 요청 이름)여야 한다 */
_Static_assert(offsetof(struct evt_exec_path, filename) == 32, "evt_exec_path.filename 위치");

static int failures;

#define CHECK(cond, msg) do { \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { printf("  FAIL  %s\n", msg); failures++; } \
} while (0)

/*
 * 이벤트 한 줄을 메모리에 쓰고, ",\"event\":" 뒤부터 줄 끝(개행 포함)까지를 out 에 복사한다.
 * 머리의 logged_at_ms 는 실행할 때마다 달라서 비교 대상에서 뺀다. 못 찾으면 out 은 빈 문자열이다.
 */
static void event_obj(const struct event_hdr *h, size_t len, char *out, size_t outsz)
{
    char *buf = NULL;                                  /* open_memstream 이 할당하는 버퍼 */
    size_t sz = 0;                                     /* 쓴 바이트 수 */
    FILE *f = open_memstream(&buf, &sz);               /* 파일 대신 메모리에 쓰는 FILE* */
    out[0] = '\0';
    if (!f)
        return;
    jsonl_write_event(f, "s-test", h, len);            /* 검증 대상 */
    fclose(f);                                         /* 닫아야 buf 와 sz 가 확정된다 */
    const char *p = buf ? strstr(buf, ",\"event\":") : NULL;   /* event 객체의 시작 */
    if (p)
        snprintf(out, outsz, "%s", p + strlen(",\"event\":"));
    free(buf);
}

/* 합성 EXEC_PATH. memset 으로 패딩과 문자열 칸의 남은 영역을 0 으로 채운다 */
static struct evt_exec_path make_path(const char *req, const char *fin,
                                      const char *par, const char *gpar)
{
    struct evt_exec_path e;
    memset(&e, 0, sizeof(e));
    e.hdr.kind = EVT_EXEC_PATH;
    e.hdr.pid = 300;
    e.hdr.cgroup_id = 7;
    e.hdr.ts_ns = 5000;
    e.hdr.payload_len = sizeof(e) - sizeof(e.hdr);
    snprintf(e.filename, sizeof(e.filename), "%s", req);
    snprintf(e.final_name, sizeof(e.final_name), "%s", fin);
    snprintf(e.parent_name, sizeof(e.parent_name), "%s", par);
    snprintf(e.grandparent_name, sizeof(e.grandparent_name), "%s", gpar);
    return e;
}

/* (a) 필드 네 개가 정해진 이름과 순서로 나온다 (memfd 를 경로 문자열로 실행한 모양) */
static void test_fields(void)
{
    printf("[a] EXEC_PATH 필드 출력\n");
    struct evt_exec_path e = make_path("/proc/self/fd/3", "memfd:x", "/", "/");
    char out[2048];
    event_obj(&e.hdr, sizeof(e), out, sizeof(out));
    CHECK(strcmp(out, "{\"kind\":\"EXEC_PATH\",\"pid\":300,\"cgroup_id\":7,\"ts_ns\":5000,"
                      "\"filename\":\"/proc/self/fd/3\",\"final_name\":\"memfd:x\","
                      "\"parent_name\":\"/\",\"grandparent_name\":\"/\"}}\n") == 0,
          "요청 이름, 최종 이름, 부모, 조부모가 순서대로 나온다");

    /* 부모와 조부모가 서로 다른 값이어야 필드가 섞이지 않았음을 확인할 수 있다 */
    e = make_path("/usr/bin/python3", "python3.14", "bin", "usr");
    event_obj(&e.hdr, sizeof(e), out, sizeof(out));
    CHECK(strstr(out, "\"filename\":\"/usr/bin/python3\",\"final_name\":\"python3.14\","
                      "\"parent_name\":\"bin\",\"grandparent_name\":\"usr\"}") != NULL,
          "네 칸이 각각 자기 값을 낸다 (python3 -> python3.14, bin, usr)");
}

/* (a) 공격자가 정할 수 있는 이름의 따옴표, 역슬래시, 개행이 이스케이프된다 */
static void test_escape(void)
{
    printf("[a] 이스케이프\n");
    struct evt_exec_path e = make_path("./x\"y", "a\\b", "c\nd", "e\x01" "f");
    char out[2048];
    event_obj(&e.hdr, sizeof(e), out, sizeof(out));
    CHECK(strstr(out, "\"filename\":\"./x\\\"y\",\"final_name\":\"a\\\\b\","
                      "\"parent_name\":\"c\\nd\",\"grandparent_name\":\"e\\u0001f\"}") != NULL,
          "따옴표, 역슬래시, 개행, 제어 문자가 이스케이프된다");
    CHECK(strchr(out, '\n') == out + strlen(out) - 1, "줄바꿈은 줄 끝 하나뿐이다 (이름 안의 개행이 줄을 가르지 않음)");
}

/* (a) 칸을 꽉 채운 이름(NUL 없음)도 칸 크기에서 멈춘다 */
static void test_full_name(void)
{
    printf("[a] 칸을 꽉 채운 이름\n");
    struct evt_exec_path e = make_path("/tmp/long", "", "tmp", "/");
    memset(e.final_name, 'A', sizeof(e.final_name));   /* NUL 종료 없이 64바이트 */
    char out[2048];
    event_obj(&e.hdr, sizeof(e), out, sizeof(out));
    char want[128];
    snprintf(want, sizeof(want), "\"final_name\":\"%.*s\",\"parent_name\":\"tmp\"", MAX_DNAME,
             "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    CHECK(strstr(out, want) != NULL, "final_name 은 64바이트에서 끊기고 다음 칸을 침범하지 않는다");
}

/* (b) 길이가 모자라면 헤더 필드만 내고 이름 칸은 읽지 않는다 (EXEC/TAG_HIT 과 같은 관례) */
static void test_short(void)
{
    printf("[b] 길이 부족\n");
    struct evt_exec_path e = make_path("/bin/ls", "busybox", "bin", "/");
    char out[2048];
    event_obj(&e.hdr, sizeof(e) - 1, out, sizeof(out));
    CHECK(strcmp(out, "{\"kind\":\"EXEC_PATH\",\"pid\":300,\"cgroup_id\":7,\"ts_ns\":5000}}\n") == 0,
          "sizeof - 1 이면 이름 필드 없이 헤더만 나온다");
    event_obj(&e.hdr, sizeof(struct event_hdr), out, sizeof(out));
    CHECK(strstr(out, "filename") == NULL, "헤더 길이만이면 filename 도 없다");
}

/* (d) 새 종류 이름이 UNKNOWN 이 아니다 */
static void test_kind_name(void)
{
    printf("[d] 종류 이름\n");
    struct evt_exec_path e = make_path("/bin/ls", "busybox", "bin", "/");
    char out[2048];
    event_obj(&e.hdr, sizeof(e), out, sizeof(out));
    CHECK(strstr(out, "\"kind\":\"EXEC_PATH\"") != NULL, "kind 가 EXEC_PATH 다");
    CHECK(strstr(out, "UNKNOWN") == NULL, "UNKNOWN 이 아니다");
}

/* (c) 기존 종류의 출력이 한 글자도 바뀌지 않았다 (변경 전 형식을 그대로 적어 둔다) */
static void test_old_kinds(void)
{
    printf("[c] 기존 EXEC, TAG_HIT 출력\n");
    char out[2048];

    struct evt_exec x;
    memset(&x, 0, sizeof(x));
    x.hdr.kind = EVT_EXEC;
    x.hdr.pid = 100;
    x.hdr.cgroup_id = 7;
    x.hdr.ts_ns = 4000;
    x.hdr.payload_len = sizeof(x.filename);
    snprintf(x.filename, sizeof(x.filename), "%s", "/usr/bin/ls");
    event_obj(&x.hdr, sizeof(x), out, sizeof(out));
    CHECK(strcmp(out, "{\"kind\":\"EXEC\",\"pid\":100,\"cgroup_id\":7,\"ts_ns\":4000,"
                      "\"filename\":\"/usr/bin/ls\"}}\n") == 0,
          "EXEC 줄 형식이 그대로다");

    struct evt_tag_hit t;
    memset(&t, 0, sizeof(t));
    t.hdr.kind = EVT_TAG_HIT;
    t.hdr.pid = 200;
    t.hdr.cgroup_id = 7;
    t.hdr.ts_ns = 4500;
    t.hdr.payload_len = sizeof(t) - sizeof(t.hdr);
    t.exec_cgroup_id = 9;
    t.tag_ts_ns = 4400;
    t.tag_write_count = 1;
    t.dev = 40;
    t.ino = 3938722;
    snprintf(t.filename, sizeof(t.filename), "%s", "./c1");
    event_obj(&t.hdr, sizeof(t), out, sizeof(out));
    CHECK(strcmp(out, "{\"kind\":\"TAG_HIT\",\"pid\":200,\"cgroup_id\":7,\"ts_ns\":4500,"
                      "\"exec_cgroup_id\":9,\"tag_ts_ns\":4400,\"tag_write_count\":1,\"dev\":40,\"ino\":3938722,"
                      "\"filename\":\"./c1\"}}\n") == 0,
          "TAG_HIT 줄 형식이 그대로다");
}

int main(void)
{
    test_fields();
    test_escape();
    test_full_name();
    test_short();
    test_kind_name();
    test_old_kinds();
    printf("\n%s (실패 %d)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
