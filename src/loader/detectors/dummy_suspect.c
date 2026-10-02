/*
 * dummy_suspect.c
 *
 * ===== 이 파일의 역할 =====
 * 더미 탐지기. 모든 EXEC 이벤트에 SUSPECT 판정을 낸다.
 * 탐지가 목적이 아니라 "이벤트 -> 디스패처 -> 탐지기 -> 판정" 배관이 통하는지
 * 확인하는 용도다. 실제 탐지기는 2주차부터 만든다.
 *
 * ===== 탐지기 파일의 기본 틀 =====
 * 새 탐지기는 이 파일과 같은 세 부분으로 구성하면 된다.
 *   1) on_event 함수   : 판단 로직
 *   2) struct detector : 이름, 구독 종류, on_event 연결
 *   3) 생성자 함수      : 스스로 디스패처에 등록
 * 이 파일을 detectors/ 에 넣기만 하면 build.sh 의 와일드카드로 빌드에 포함되고
 * 스스로 등록하므로, 로더나 디스패처 코드는 한 줄도 수정하지 않는다.
 */
#include <stdio.h>
#include "detector.h"
#include "dispatcher.h"

/*
 * 판단 로직. 더미라서 이벤트 내용을 보지 않고 항상 "의심"을 돌려준다.
 * static: 이 파일 안에서만 쓰는 함수라는 뜻. 다른 탐지기 파일에도 on_event 라는
 *         이름이 있어도 서로 충돌하지 않는다.
 * (void)h; (void)len; : 쓰지 않는 인자 때문에 컴파일러가 경고(-Wextra)하지 않도록
 *                       "일부러 안 쓴다"고 표시하는 관용구. 기능은 없다.
 */
static int on_event(const struct event_hdr *h, size_t len, struct verdict *out)
{
    (void)h;
    (void)len;

    out->level = V_SUSPECT;
    /*
     * snprintf(목적지, 목적지 크기, 형식, ...): 크기를 넘지 않게 잘라서 쓴다.
     * 크기를 모르는 sprintf 는 버퍼 오버플로의 원인이므로 쓰지 않는다.
     */
    snprintf(out->reason, sizeof(out->reason), "dummy: 모든 EXEC 는 의심");
    return 1;                                         /* 1 = 판정 있음 */
}

/*
 * 탐지기 정의. ".필드 = 값" 형태는 "지정 초기화(designated initializer)"로,
 * 필드 순서와 상관없이 이름으로 값을 넣는다. 적지 않은 필드(err_streak, disabled)는 0 이 된다.
 * 함수 이름 on_event 는 괄호 없이 쓰면 "함수의 주소"가 되어 함수 포인터 필드에 들어간다.
 * static 변수로 선언한 이유: 디스패처가 이 구조체의 "주소"를 보관하므로,
 * 함수가 끝나도 사라지지 않는 저장 공간이어야 한다.
 */
static struct detector det = {
    .name = "dummy_suspect",
    .kinds = KIND_BIT(EVT_EXEC),                      /* EXEC 이벤트만 구독 */
    .on_event = on_event,
};

/*
 * 자동 등록.
 * __attribute__((constructor)) 는 GCC/Clang 확장으로, 이 함수를 main() 이 시작되기 전에
 * 자동으로 호출하게 한다. 그래서 로더의 main 에서 "이 탐지기를 등록해라"라고 적을 필요가 없다.
 * 주의: 이 파일을 정적 라이브러리(.a)로 묶으면 아무도 이 파일의 심볼을 참조하지 않아
 * 링크 단계에서 통째로 빠지고 생성자도 실행되지 않는다. 그래서 build.sh 는 .c 를 직접 나열한다.
 */
__attribute__((constructor))
static void register_me(void)
{
    register_detector(&det);
}
