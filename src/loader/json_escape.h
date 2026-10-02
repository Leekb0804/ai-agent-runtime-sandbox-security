/*
 * json_escape.h
 *
 * ===== 왜 필요한가 (로그 위조 방지) =====
 * 이벤트의 파일 경로 같은 문자열은 "공격자가 정할 수 있는 값"이다.
 * 예를 들어 에이전트가 이런 이름의 파일을 실행했다고 하자.
 *
 *     x"}\n{"type":"verdict","level":"SUSPECT"...
 *
 * 이 이름을 이스케이프 없이 JSON 줄에 그대로 끼워 넣으면, 로그 파서는 한 줄이 아니라
 * 두 줄로 읽고 가짜 판정 줄이 로그에 생긴다. 즉 로그를 위조할 수 있다.
 * 그래서 외부에서 온 문자열은 항상 이 함수를 거쳐 출력한다.
 */
#ifndef JSON_ESCAPE_H
#define JSON_ESCAPE_H

#include <stdio.h>                /* FILE */
#include <stddef.h>               /* size_t */

/*
 * s 를 JSON 문자열 리터럴로 만들어 f 에 쓴다. 양쪽 따옴표도 함수가 붙인다.
 *   f      : 출력 대상 (stdout 이나 파일, 테스트에서는 메모리 스트림)
 *   s      : 출력할 문자열
 *   maxlen : 최대 읽을 바이트 수. NUL('\0')을 만나면 그 전에 멈춘다.
 *            s 가 NUL 로 끝나지 않는 고정 크기 배열이어도 maxlen 을 넘어 읽지 않아 안전하다.
 *
 * 이스케이프 대상: 따옴표(") 역슬래시(\) 그리고 제어 문자(0x00~0x1f, 0x7f).
 * 한계: 0x80 이상의 바이트는 그대로 통과시킨다. 한글 같은 정상 UTF-8 은 문제없지만,
 *       유효하지 않은 UTF-8 바이트열은 일부 JSON 파서가 거부할 수 있다.
 */
void json_put_string(FILE *f, const char *s, size_t maxlen);

#endif /* JSON_ESCAPE_H */
