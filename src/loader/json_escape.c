/*
 * json_escape.c
 *
 * 문자열을 JSON 규칙에 맞게 이스케이프해서 출력한다. (이유는 json_escape.h 참고)
 */
#include "json_escape.h"

void json_put_string(FILE *f, const char *s, size_t maxlen)
{
    fputc('"', f);                                    /* 여는 따옴표 */

    /*
     * 문자열을 한 바이트씩 읽는다. 조건 두 개를 모두 만족하는 동안 반복:
     *   i < maxlen       : 최대 길이를 넘어 읽지 않는다 (NUL 이 없는 배열 방어)
     *   s[i] != '\0'     : 문자열 끝(NUL)을 만나면 멈춘다
     * 두 조건 중 순서가 중요하다. i < maxlen 을 먼저 검사해야, maxlen 에 도달했을 때
     * s[i] 를 읽지 않는다 (&& 는 앞이 거짓이면 뒤를 검사하지 않는다).
     */
    for (size_t i = 0; i < maxlen && s[i] != '\0'; i++) {
        /*
         * char 는 환경에 따라 부호가 있을 수 있어서, 0x80 이상 바이트가 음수가 되면
         * 아래 비교(c < 0x20)가 잘못 동작한다. unsigned char 로 바꿔서 0~255 로 다룬다.
         */
        unsigned char c = (unsigned char)s[i];

        switch (c) {
        /* JSON 이 반드시 이스케이프를 요구하는 문자들. C 문자열에서 \ 자체를 쓰려면 \\ 로 적는다. */
        case '"':  fputs("\\\"", f); break;           /* " -> \"  */
        case '\\': fputs("\\\\", f); break;           /* \ -> \\  */

        /* 자주 쓰는 제어 문자는 짧은 형태로. 특히 개행(\n)이 그대로 나가면 로그 줄이 갈라진다. */
        case '\n': fputs("\\n", f);  break;
        case '\r': fputs("\\r", f);  break;
        case '\t': fputs("\\t", f);  break;

        default:
            if (c < 0x20 || c == 0x7f)
                /* 나머지 제어 문자는 \uXXXX 형태 (예: 0x01 -> \u0001). %04x = 16진수 4자리 0 채움 */
                fprintf(f, "\\u%04x", c);
            else
                fputc(c, f);                          /* 일반 문자는 그대로 */
        }
    }

    fputc('"', f);                                    /* 닫는 따옴표 */
}
