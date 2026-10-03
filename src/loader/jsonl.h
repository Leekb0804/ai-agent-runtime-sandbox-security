/*
 * jsonl.h
 *
 * ===== 이 파일의 역할 =====
 * 로그 한 줄(JSON Lines 레코드)을 만들어 출력하는 함수들. 화면 출력(stdout)과 세션 로그 파일이
 * 같은 형식을 쓰도록 형식을 만드는 코드를 한 곳에 모았다.
 *
 * ===== 인자 f 의 의미 =====
 * 함수 이름의 "write" 는 f 에 글자를 출력한다는 뜻이다. f 는 FILE*, 즉 글자를 내보낼 "목적지"이다.
 * 함수는 이벤트를 JSON 텍스트 한 줄로 바꿔서 f 에 출력할 뿐이고, 목적지가 어디인지는 호출하는 쪽이 정한다.
 *
 *     jsonl_write_event(stdout,    ...)   -> 화면(터미널)에 출력        (loader.c)
 *     jsonl_write_event(s->events, ...)   -> 세션의 events.jsonl 파일에 기록 (session_log.c)
 *     jsonl_write_event(메모리 스트림, ...) -> 문자열로 받아 검증          (테스트)
 *
 * printf("hi") 가 fprintf(stdout, "hi") 와 같은 것처럼, 출력 대상을 직접 지정하는 방식이다.
 * 그래서 화면과 파일에 "같은 형식"이 나온다.
 *
 * 이 함수들이 하지 않는 일:
 *   - f 를 열거나 닫지 않는다 (호출하는 쪽의 몫)
 *   - fflush 를 하지 않는다 (내보내는 시점도 호출하는 쪽이 정한다. 이유는 session_log.c 의 session_write_event 참고)
 *   이렇게 "형식 만들기"와 "목적지 관리"를 분리해 두어서, 테스트에서는 메모리에 쓰는 FILE* 를 넘겨
 *   결과를 문자열로 받아 검증할 수 있다.
 *
 * ===== 레코드의 종류 =====
 * 모두 한 줄이고 "type" 필드로 구분한다. 한 줄은 항상 "\n" 으로 끝난다.
 *   event   : 커널이 보낸 이벤트 (events.jsonl)
 *   verdict : 탐지기가 낸 판정 (verdicts.jsonl)
 *   action  : 판정에 따른 대응 기록. 지금은 kill 스텁의 "would_kill" (verdicts.jsonl)
 *
 * 외부에서 온 문자열(파일 경로 등)은 전부 json_put_string 으로 이스케이프해서 쓴다.
 * (공격자가 정한 문자열로 로그에 줄을 끼워 넣는 위조를 막으려는 것이다. json_escape.h 참고)
 */
#ifndef JSONL_H
#define JSONL_H

#include <stdio.h>
#include <stddef.h>
#include <linux/types.h>          /* event.h 의 __u32/__u64. event.h 보다 먼저! */
#include "bpf/event.h"
#include "detector.h"

/*
 * 로그 스키마 버전. 0 = 초안(필드가 바뀔 수 있음).
 * 5주차에 로그 스키마를 확정하면서 1 로 올린다.
 */
#define LOG_SCHEMA_VERSION 0

/* 이벤트 한 줄을 f 에 쓴다. session 은 이 이벤트가 속한 세션 ID. */
void jsonl_write_event(FILE *f, const char *session,
                       const struct event_hdr *h, size_t len);

/* 판정 한 줄을 f 에 쓴다. 원인이 된 이벤트의 정보도 함께 넣는다. */
void jsonl_write_verdict(FILE *f, const char *session,
                         const struct event_hdr *h, size_t len,
                         const struct verdict *v);

/* 대응(action) 한 줄을 f 에 쓴다. 예: action="would_kill" */
void jsonl_write_action(FILE *f, const char *session, __u64 cgroup_id,
                        const char *action, const char *reason);

#endif /* JSONL_H */
