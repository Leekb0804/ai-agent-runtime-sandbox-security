/*
 * loader_args.h
 *
 * 역할: 로더(myc_loader)의 명령줄 인자 해석. main 은 단위 테스트하기 어려워서 해석만 떼어 둔다.
 * 헤더 하나로 끝나며(loader_lock.h 와 같은 방식) test_loader_args.c 가 sudo 없이 검증한다.
 *
 * 받는 인자 (순서는 상관없다):
 *   [세션 루트]          위치 인자 0~1개. 없으면 호출한 쪽이 기본값을 쓴다 (예전의 argv[1] 과 같은 뜻)
 *   --detectors=a,b,c   켤 탐지기 이름 목록 (dispatcher_select 참고)
 *   --no-kill           관찰 모드. BLOCK 이어도 세션을 종료하지 않고 would_kill 만 기록한다 (평가용, kill.h 참고)
 *
 * 잘못된 인자는 모두 거부한다 (fail-closed). 잘못 읽고 시작하면 "엉뚱한 폴더에 기록"하거나
 * "탐지기가 빠진 채 감시"하면서도 정상처럼 보이기 때문이다:
 *   - 알 수 없는 옵션 (- 로 시작하는 모든 인자. 그래서 세션 루트도 - 로 시작할 수 없다)
 *   - 위치 인자 2개 이상, 빈 위치 인자
 *   - --detectors 두 번, 값이 비었거나 a,,b 처럼 빈 칸, 이름이 너무 김, 개수가 MAX_DETECTORS 초과
 *   - --no-kill 두 번, --no-kill=값 처럼 값이 붙은 것 (값을 받지 않는 옵션이라 모르는 옵션으로 본다)
 * 같은 이름 두 번이나 등록되지 않은 이름은 여기서 보지 않고 dispatcher_select 가 거부한다.
 */
#ifndef LOADER_ARGS_H
#define LOADER_ARGS_H

#include <stdio.h>
#include <string.h>
#include "dispatcher.h"           /* MAX_DETECTORS */

/* 탐지기 이름 하나의 최대 길이 (NUL 포함) */
#define LOADER_ARGS_NAME_MAX 64

#define LOADER_ARGS_DETECTORS_OPT "--detectors="
#define LOADER_ARGS_NO_KILL_OPT   "--no-kill"

struct loader_args {
    const char *root;                                   /* 세션 루트 (argv 안을 가리킴). 없으면 NULL */
    int has_detectors;                                  /* --detectors 를 받았는가 */
    int no_kill;                                        /* --no-kill 을 받았는가 (관찰 모드) */
    int n_detectors;                                    /* 받은 이름 개수 */
    char detectors[MAX_DETECTORS][LOADER_ARGS_NAME_MAX];  /* 받은 이름들 (복사본) */
    const char *names[MAX_DETECTORS];                   /* detectors 의 각 칸을 가리킴 (dispatcher_select 에 그대로 넘긴다) */
};

/*
 * "a,b,c" 를 out->detectors 에 나눠 담는다. 반환: 0 성공, -1 거부 (err 에 이유)
 */
static inline int loader_args_split(const char *val, struct loader_args *out, char *err, size_t errlen)
{
    if (val[0] == '\0') {
        snprintf(err, errlen, "--detectors= 의 값이 비었음");
        return -1;
    }
    const char *p = val;
    for (;;) {
        /* 다음 쉼표까지가 이름 하나이다. 쉼표가 없으면 문자열 끝까지 */
        const char *comma = strchr(p, ',');
        size_t n = comma ? (size_t)(comma - p) : strlen(p);
        if (n == 0) {
            snprintf(err, errlen, "--detectors 에 빈 이름이 있음: %s", val);
            return -1;
        }
        if (n >= LOADER_ARGS_NAME_MAX) {
            snprintf(err, errlen, "--detectors 의 이름이 너무 김 (최대 %d자)", LOADER_ARGS_NAME_MAX - 1);
            return -1;
        }
        if (out->n_detectors >= MAX_DETECTORS) {
            snprintf(err, errlen, "--detectors 의 이름이 너무 많음 (최대 %d개)", MAX_DETECTORS);
            return -1;
        }
        memcpy(out->detectors[out->n_detectors], p, n);
        out->detectors[out->n_detectors][n] = '\0';
        out->names[out->n_detectors] = out->detectors[out->n_detectors];
        out->n_detectors++;
        if (!comma)
            return 0;
        p = comma + 1;
    }
}

/*
 * argv 를 해석해 out 을 채운다. out 은 이 함수가 처음부터 다시 채운다.
 * 반환: 0 성공, -1 거부 (err 에 사람이 읽을 이유. 호출한 쪽이 사용법과 함께 출력하고 종료한다)
 */
static inline int loader_parse_args(int argc, char **argv, struct loader_args *out, char *err, size_t errlen)
{
    const size_t optlen = strlen(LOADER_ARGS_DETECTORS_OPT);

    memset(out, 0, sizeof(*out));
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strncmp(a, LOADER_ARGS_DETECTORS_OPT, optlen) == 0) {
            /* --detectors=… 는 한 번만 */
            if (out->has_detectors) {
                snprintf(err, errlen, "--detectors 가 두 번 있음");
                return -1;
            }
            out->has_detectors = 1;
            if (loader_args_split(a + optlen, out, err, errlen) != 0)
                return -1;
        } else if (strcmp(a, LOADER_ARGS_NO_KILL_OPT) == 0) {
            /* --no-kill 은 값 없이 정확히 이 글자만. 한 번만 (--no-kill=값 은 아래에서 모르는 옵션이 된다) */
            if (out->no_kill) {
                snprintf(err, errlen, "--no-kill 이 두 번 있음");
                return -1;
            }
            out->no_kill = 1;
        } else if (a[0] == '-') {
            /* 그 밖의 - 로 시작하는 인자는 모두 모르는 옵션 (--detectors 를 = 없이 쓴 경우, --no-kill=값, - 하나도 포함) */
            snprintf(err, errlen, "알 수 없는 옵션: %s (세션 루트는 - 로 시작할 수 없음)", a);
            return -1;
        } else if (a[0] == '\0') {
            snprintf(err, errlen, "세션 루트가 빈 문자열임");
            return -1;
        } else {
            /* 위치 인자 = 세션 루트. 하나만 */
            if (out->root) {
                snprintf(err, errlen, "세션 루트가 두 번 있음: %s, %s", out->root, a);
                return -1;
            }
            out->root = a;
        }
    }
    return 0;
}

#endif /* LOADER_ARGS_H */
