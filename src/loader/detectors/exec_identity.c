/*
 * exec_identity.c
 *
 * ===== 이 파일의 역할 =====
 * 실행 정체성 탐지기. exec 요청 이름과 실제로 실행되는 파일의 이름(EXEC_PATH)을 비교해 판정한다.
 * 규칙은 docs/exec-identity-scenarios-w4.md 4절을 따른다.
 *
 *   규칙 M: 최종 dentry 이름이 "memfd:" 로 시작 (메모리에서 실행)                      -> SUSPECT
 *   규칙 L: 요청 이름의 basename 과 최종 이름이 다르고, 최종 파일이 임시 위치 바로 아래 -> SUSPECT
 *
 * 한 이벤트에서 판정은 최대 하나다. 규칙 M 을 먼저 보고, 맞으면 L 은 보지 않는다.
 * 이벤트 하나만으로 판정하므로 상태가 없다. 판정은 exec 이후의 사후 판정이라 실행 자체를 막지 못한다.
 *
 * ===== 알려진 한계 =====
 * - 이름이 세 단계(최종, 부모, 조부모)뿐이다. /tmp/sub/x 는 (x, sub, tmp)라서 "/tmp 안" 으로 가리지 못하고,
 *   어느 /<d>/var/tmp/x 도 /var/tmp/x 와 같은 (x, tmp, var)로 보여서 구분하지 못한다.
 * - 임시 위치 목록(tmp_dirs) 밖에 둔 위장(예: 작업 폴더 안의 링크)은 보지 않는다.
 * - 쓰기 이력을 보지 않는다. "세션이 쓴 파일을 실행" 은 write_exec_boundary 가 담당한다.
 * - 이름 칸은 64바이트라 63바이트에서 잘린다. 그래서 규칙 L 은 잘린 이름을 앞 63바이트로만 비교한다.
 */
#include <stdio.h>
#include <string.h>
#include "detector.h"
#include "dispatcher.h"

/* 규칙 M 의 접두어와 그 길이. 길이는 접두어 비교와 최소 길이 검사에 함께 쓴다 */
#define MEMFD_PREFIX "memfd:"
#define MEMFD_PREFIX_LEN 6

/* 이름 칸에서 잘림 없이 믿을 수 있는 최대 길이 (64바이트 칸의 마지막은 NUL 자리) */
#define NAME_CMP_MAX (MAX_DNAME - 1)

/*
 * 이유 문자열에 넣을 최대 바이트 수. reason 은 128바이트(127자 + NUL)이고 고정 문구의 한글이 글자당 3바이트라서
 * 요청 이름과 최종 이름을 이만큼으로 줄여야 문구 전체가 들어간다. 넘치면 snprintf 가 뒤를 자른다.
 */
#define REASON_REQ_MAX 40     /* 규칙 M 의 요청 이름 (고정 문구 51바이트 + 40 + 24 = 115) */
#define REASON_FINAL_MAX 24   /* 규칙 M 의 최종 이름 */
#define REASON_L_REQ_MAX 20   /* 규칙 L 의 요청 basename, 잘림 표시 '~' 포함 (고정 문구 84바이트 + 위치 최대 8 + 20 + 15 = 127) */
#define REASON_L_FINAL_MAX 15 /* 규칙 L 의 최종 이름 */

/*
 * 임시 위치 목록: (조부모 이름, 부모 이름) 쌍과 이유 문자열에 보일 경로. 최종 파일의 부모·조부모가 이 중 하나와 같으면
 * 임시 위치 바로 아래다. 컨테이너 안 경로는 overlay 기준이라 /tmp/x 는 (x, tmp, /), /var/tmp/x 는 (x, tmp, var)로 보인다 (VM 실측).
 * 표시용 경로를 더 길게 바꾸면 REASON_L_REQ_MAX 계산(위치 최대 8바이트)도 다시 해야 한다.
 */
static const struct {
    const char *grandparent;   /* 조부모 dentry 이름 */
    const char *parent;        /* 부모 dentry 이름 */
    const char *label;         /* 이유 문자열에 보일 경로 (ASCII) */
} tmp_dirs[] = {
    { "/",   "tmp", "/tmp" },          /* /tmp */
    { "var", "tmp", "/var/tmp" },      /* /var/tmp */
};

/* 이름 칸 field(크기 MAX_DNAME, NUL 이 없을 수 있음)가 문자열 s 와 정확히 같은가 */
static int name_eq(const char *field, const char *s)
{
    size_t n = strnlen(field, MAX_DNAME);                /* 칸 안에서만 길이를 잰다 */
    return n == strlen(s) && memcmp(field, s, n) == 0;   /* 길이와 내용이 모두 같아야 같다 */
}

/* 규칙 M: 최종 이름이 "memfd:" 로 시작하는가 (콜론 뒤가 비어 있어도 접두어가 맞으면 참) */
static int is_memfd(const char *final_name)
{
    size_t n = strnlen(final_name, MAX_DNAME);           /* 칸 안에서만 길이를 잰다 */
    return n >= MEMFD_PREFIX_LEN                         /* 접두어보다 짧으면 아니다 */
        && memcmp(final_name, MEMFD_PREFIX, MEMFD_PREFIX_LEN) == 0;   /* 앞 6바이트가 정확히 같아야 한다 */
}

/*
 * 요청 이름의 basename 을 찾는다. 마지막 '/' 뒤, '/' 가 없으면 전체.
 * filename 은 NUL 이 없을 수 있어서 MAX_FILENAME 안에서만 읽는다. *blen 에 basename 길이를 쓴다.
 */
static const char *req_basename(const char *filename, size_t *blen)
{
    size_t n = strnlen(filename, MAX_FILENAME);          /* 칸 안에서만 길이를 잰다 */
    size_t start = 0;                                    /* basename 시작 위치 (기본: 처음) */
    for (size_t i = 0; i < n; i++) {                     /* 앞에서부터 훑으며 */
        if (filename[i] == '/')                          /* '/' 를 만날 때마다 */
            start = i + 1;                               /* 그 다음 칸을 basename 시작으로 둔다 */
    }
    *blen = n - start;                                   /* '/' 로 끝나면 0 이 된다 */
    return filename + start;                             /* basename 의 시작 주소 */
}

/*
 * 요청 basename 과 최종 이름이 같은가.
 * 최종 이름이 63바이트 이상이면(칸이 꽉 차 잘렸을 수 있음) 앞 63바이트만 비교한다 (긴 이름의 오탐 방지).
 */
static int same_name(const char *base, size_t blen, const char *final_name)
{
    size_t flen = strnlen(final_name, MAX_DNAME);        /* 칸 안에서만 길이를 잰다 (최대 64) */
    if (flen >= NAME_CMP_MAX)                            /* 잘렸을 수 있는 이름이면 */
        return blen >= NAME_CMP_MAX && memcmp(base, final_name, NAME_CMP_MAX) == 0;   /* 앞 63바이트만 비교 */
    return blen == flen && memcmp(base, final_name, flen) == 0;   /* 아니면 길이와 내용이 모두 같아야 같다 */
}

/* 최종 파일이 임시 위치 바로 아래인가. 맞으면 그 목록 칸의 번호, 아니면 -1 */
static int tmp_dir_index(const struct evt_exec_path *e)
{
    for (size_t i = 0; i < sizeof(tmp_dirs) / sizeof(tmp_dirs[0]); i++) {   /* 목록을 차례로 보며 */
        if (name_eq(e->parent_name, tmp_dirs[i].parent)                     /* 부모가 같고 */
            && name_eq(e->grandparent_name, tmp_dirs[i].grandparent))       /* 조부모도 같으면 */
            return (int)i;                                                   /* 그 칸 번호 */
    }
    return -1;                                                               /* 목록에 없음 */
}

/* 최종 이름을 이유 문자열에 넣을 길이 (칸 안의 길이와 max 중 작은 쪽) */
static int final_show_len(const char *final_name, size_t max)
{
    size_t n = strnlen(final_name, MAX_DNAME);           /* 칸 안에서만 길이를 잰다 */
    return (int)(n < max ? n : max);                     /* 이유에 넣을 바이트 수 */
}

static int on_event(const struct event_hdr *h, size_t len, struct verdict *out)
{
    /* 구조체로 읽기 전에 길이를 확인한다 (디스패처는 EXEC_PATH 의 헤더 길이만 검사한다) */
    if (len < sizeof(struct evt_exec_path))
        return -1;

    const struct evt_exec_path *e = (const struct evt_exec_path *)h;   /* 길이를 확인했으니 해석한다 */
    int n;                                                             /* snprintf 반환값 */

    /* 규칙 M: 메모리에서 실행. 맞으면 L 은 보지 않는다 (한 이벤트에 판정 하나) */
    if (is_memfd(e->final_name)) {
        out->level = V_SUSPECT;                                        /* 기록만 한다 */
        /* 요청 이름과 최종 이름은 에이전트가 정할 수 있는 값이라 칸 안에서 %.*s 로 길이를 제한한다 */
        n = snprintf(out->reason, sizeof(out->reason), "[M] 메모리에서 실행(memfd): 요청 %.*s, 실제 %.*s",
                     (int)REASON_REQ_MAX, e->filename,
                     final_show_len(e->final_name, REASON_FINAL_MAX), e->final_name);
        return n < 0 ? -1 : 1;                                         /* 음수는 변환 오류 */
    }

    /* 규칙 L 의 조건 1: 요청 basename 이 비어 있지 않다 */
    size_t blen;                                                       /* basename 길이 */
    const char *base = req_basename(e->filename, &blen);               /* 요청 이름의 basename */
    if (blen == 0)                                                     /* 빈 요청 이름이거나 '/' 로 끝남 */
        return 0;

    /* 최종 이름이 비어 있으면(커널에서 못 읽음) 비교할 대상이 없으므로 판정하지 않는다 */
    if (e->final_name[0] == '\0')
        return 0;

    /* 조건 2: 요청 basename 과 최종 이름이 다르다 */
    if (same_name(base, blen, e->final_name))
        return 0;

    /* 조건 3: 최종 파일이 임시 위치 바로 아래다 */
    int t = tmp_dir_index(e);                                          /* 맞은 임시 위치 칸 번호 */
    if (t < 0)
        return 0;

    out->level = V_SUSPECT;                                            /* 기록만 한다 */
    /* 요청 이름은 basename 을 보인다. 길면 앞 (REASON_L_REQ_MAX - 1)바이트와 잘림 표시 '~' 를 보인다 */
    int cut = blen > REASON_L_REQ_MAX;                                 /* basename 이 표시 한도보다 긴가 */
    int req_show = cut ? REASON_L_REQ_MAX - 1 : (int)blen;             /* 보일 basename 바이트 수 */
    /* base 는 NUL 로 끝나지 않을 수 있지만 %.*s 가 req_show 바이트까지만 읽는다. 위치는 목록의 표시용 문자열 */
    n = snprintf(out->reason, sizeof(out->reason),
                 "[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 %.*s%s, 실제 %.*s (위치 %s)",
                 req_show, base, cut ? "~" : "",
                 final_show_len(e->final_name, REASON_L_FINAL_MAX), e->final_name,
                 tmp_dirs[t].label);
    return n < 0 ? -1 : 1;                                             /* 음수는 변환 오류 */
}

/* 탐지기 정의. EXEC_PATH 만 구독한다 (운영 탐지기라 --detectors 없이도 켜진다) */
static struct detector det = {
    .name = "exec_identity",
    .kinds = KIND_BIT(EVT_EXEC_PATH),
    .on_event = on_event,
};

/* main() 이전에 자동 호출되어 디스패처에 등록한다. detectors 폴더에 .c 파일을 두면 build.sh 가 자동으로 포함한다. */
__attribute__((constructor))
static void register_me(void)
{
    register_detector(&det);
}
