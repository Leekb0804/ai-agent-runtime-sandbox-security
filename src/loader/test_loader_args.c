/*
 * test_loader_args.c
 *
 * loader_args.h 의 단위 테스트. 커널 프로그램, libbpf, sudo 가 필요 없다.
 * 받아들여야 하는 인자와 거부해야 하는 인자를 모두 넣어 본다.
 * 종료 코드: 0 통과, 1 실패
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "loader_args.h"

static int failures;

#define CHECK(cond, name) do { \
    if (cond) printf("PASS: %s\n", name); \
    else { printf("FAIL: %s\n", name); failures++; } \
} while (0)

/* 결과를 담을 곳. 크기가 커서 static 으로 둔다 */
static struct loader_args a;
static char err[256];

/* argv[0] 을 붙여 해석한다. 인자 목록은 NULL 로 끝난다 */
static int parse(const char *first, ...)
{
    char *argv[32];
    int argc = 0;
    argv[argc++] = "myc_loader";
    va_list ap;
    va_start(ap, first);
    for (const char *s = first; s && argc < 31; s = va_arg(ap, const char *))
        argv[argc++] = (char *)s;
    va_end(ap);
    argv[argc] = NULL;
    err[0] = '\0';
    return loader_parse_args(argc, argv, &a, err, sizeof(err));
}

/* 받은 이름 목록이 기대와 같은가 (순서까지) */
static int names_are(int n, const char *x0, const char *x1, const char *x2)
{
    const char *want[3] = { x0, x1, x2 };
    if (!a.has_detectors || a.n_detectors != n)
        return 0;
    for (int i = 0; i < n; i++) {
        if (strcmp(a.names[i], want[i]) != 0 || a.names[i] != a.detectors[i])
            return 0;
    }
    return 1;
}

int main(void)
{
    /* ---------- 받아들임 ---------- */
    CHECK(parse(NULL) == 0 && a.root == NULL && !a.has_detectors && a.n_detectors == 0,
          "accept_no_args");
    CHECK(parse("/tmp/s", NULL) == 0 && a.root && strcmp(a.root, "/tmp/s") == 0 && !a.has_detectors,
          "accept_root_only_compat");
    CHECK(parse("--detectors=a,b,c", NULL) == 0 && a.root == NULL && names_are(3, "a", "b", "c"),
          "accept_detectors_only");
    CHECK(parse("--detectors=x,y", "/tmp/s", NULL) == 0 && strcmp(a.root, "/tmp/s") == 0
          && names_are(2, "x", "y", NULL), "accept_option_before_root");
    CHECK(parse("/tmp/s", "--detectors=x", NULL) == 0 && strcmp(a.root, "/tmp/s") == 0
          && names_are(1, "x", NULL, NULL), "accept_root_before_option");
    CHECK(parse("--detectors=b,a", NULL) == 0 && names_are(2, "b", "a", NULL), "accept_keeps_given_order");

    char longest[LOADER_ARGS_NAME_MAX + 32];
    snprintf(longest, sizeof(longest), "--detectors=%0*d", LOADER_ARGS_NAME_MAX - 1, 0);
    CHECK(parse(longest, NULL) == 0 && a.n_detectors == 1 && strlen(a.names[0]) == LOADER_ARGS_NAME_MAX - 1,
          "accept_name_at_max_length");

    /* MAX_DETECTORS 개 정확히: "d0,d1,...,d15" */
    char many[1024] = "--detectors=";
    for (int i = 0; i < MAX_DETECTORS; i++)
        snprintf(many + strlen(many), sizeof(many) - strlen(many), "%sd%d", i ? "," : "", i);
    CHECK(parse(many, NULL) == 0 && a.n_detectors == MAX_DETECTORS, "accept_max_count");

    /* 같은 이름 두 번은 파서가 아니라 dispatcher_select 가 거부한다 */
    CHECK(parse("--detectors=a,a", NULL) == 0 && names_are(2, "a", "a", NULL), "accept_duplicate_left_to_select");

    /* 이전 호출의 결과가 남지 않는다 */
    parse("--detectors=a", "/tmp/s", NULL);
    CHECK(parse(NULL) == 0 && a.root == NULL && !a.has_detectors && a.n_detectors == 0, "reset_between_calls");

    /* ---------- 거부 ---------- */
    CHECK(parse("--no-kill", NULL) == -1 && strstr(err, "--no-kill"), "reject_unknown_option_no_kill");
    CHECK(parse("-x", NULL) == -1, "reject_unknown_short_option");
    CHECK(parse("-", NULL) == -1, "reject_single_dash");
    CHECK(parse("--detectors", NULL) == -1, "reject_detectors_without_equals");
    CHECK(parse("/tmp/a", "/tmp/b", NULL) == -1 && strstr(err, "/tmp/b"), "reject_two_positionals");
    CHECK(parse("-tmp", NULL) == -1, "reject_positional_starting_with_dash");
    CHECK(parse("", NULL) == -1, "reject_empty_positional");
    CHECK(parse("--detectors=", NULL) == -1, "reject_empty_value");
    CHECK(parse("--detectors=a,,b", NULL) == -1, "reject_empty_item_middle");
    CHECK(parse("--detectors=,a", NULL) == -1, "reject_empty_item_leading");
    CHECK(parse("--detectors=a,", NULL) == -1, "reject_empty_item_trailing");
    CHECK(parse("--detectors=a", "--detectors=b", NULL) == -1, "reject_detectors_twice");

    char toolong[LOADER_ARGS_NAME_MAX + 32];
    snprintf(toolong, sizeof(toolong), "--detectors=%0*d", LOADER_ARGS_NAME_MAX, 0);
    CHECK(parse(toolong, NULL) == -1, "reject_name_too_long");

    char toomany[sizeof(many) + 8];
    snprintf(toomany, sizeof(toomany), "%s,dX", many);
    CHECK(parse(toomany, NULL) == -1, "reject_too_many_names");

    if (failures) { printf("FAILED: %d\n", failures); return 1; }
    printf("ALL PASSED\n");
    return 0;
}
