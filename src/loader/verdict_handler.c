/*
 * verdict_handler.c
 *
 * 판정 수집기. 디스패처가 판정을 낼 때마다 호출된다.
 * 호출 경로: 탐지기가 판정을 냄 -> 디스패처의 g_sink(...) -> 이 파일의 handle_verdict
 */
#include "verdict_handler.h"
#include "session_log.h"
#include "jsonl.h"
#include "kill.h"

void handle_verdict(const struct event_hdr *h, size_t len,
                    const struct verdict *v, void *ctx)
{
    /*
     * void* 를 FILE* 로 해석한다 (캐스팅). 로더는 stdout 을, 테스트는 NULL 을 넘긴다.
     * NULL 이면 아래의 화면 출력을 건너뛴다.
     */
    FILE *echo = (FILE *)ctx;

    /*
     * 이벤트의 cgroup_id 로 세션 칸을 찾는다. 처음 보는 cgroup 이면 이때 by-cgroup 링크를 읽는다.
     * 세션을 못 찾아도 _unattributed 세션이 돌아오므로 s 는 항상 유효하다.
     */
    struct session *s = session_get(h->cgroup_id);

    /*
     * 1. 기록이 먼저, 대응은 그 다음.
     *    대응(kill)이 어떤 이유로 실패하거나 늦어져도 "무엇을 보고 그렇게 결정했는지"는 남아 있어야 한다.
     */
    session_write_verdict(s, h, len, v);

    /*
     * 화면에도 같은 형식으로 출력한다 (개발 중 확인용).
     * fflush 가 필요한 이유: stdout 은 출력 대상에 따라 버퍼링 방식이 다르다.
     *     터미널            : 줄 단위 (\n 마다 내보냄)  -> flush 없이도 바로 보임
     *     파이프(| tee)나 파일 : 블록 단위 (약 4KB)      -> flush 없으면 판정이 한참 뒤에야 나타남
     * 로더를 "sudo ./myc_loader | tee ..." 로 실행하면 stdout 이 파이프라서 판정이 안 보여
     * "탐지가 안 된다"고 착각하기 쉽다.
     * 또 아래의 kill 스텁은 stderr 로 알리는데 stderr 는 버퍼링이 없어 즉시 나간다. 여기서 flush 하지 않으면
     * 화면에 "대응 알림 -> 판정" 순서로 뒤바뀌어 보인다. 그래서 BLOCK 처리보다 앞에서 flush 한다.
     * 이 파일이 flush 를 책임지는 이유: echo 는 호출한 쪽이 맡긴 FILE* 이므로, 쓴 쪽이 내보내야
     * 무엇을 넘겼든(stdout 이든 다른 파일이든) 같은 동작이 보장된다. 판정은 이벤트보다 드물어 비용도 작다.
     */
    if (echo) {
        jsonl_write_verdict(echo, s->id, h, len, v);
        fflush(echo);
    }

    /*
     * 2. BLOCK 이면 세션을 종료한다. 단 한 번만 (멱등성).
     *    같은 세션에서 BLOCK 이 여러 번 와도(다른 탐지기가 각자 BLOCK 을 내는 경우 등) 종료 요청은 한 번이다.
     *    플래그를 kill_session 호출 "전에" 세운다: 호출 중에 또 BLOCK 이 들어와도 중복 호출을 막기 위해서.
     *    (kill 이 실제로 구현되는 3주차에는 실패 시 플래그를 되돌릴지 정해야 한다)
     *
     *    플래그는 이 세션의 칸(s)에 저장되어 있다. 칸이 밀려나 사라지면 플래그도 사라지는 한계가 있다.
     *    SUSPECT 는 여기서 아무 대응도 하지 않는다. 기록은 위에서 이미 끝났다.
     */
    if (v->level == V_BLOCK && !s->kill_requested) {
        s->kill_requested = 1;
        kill_session(s, v->reason);
    }
}
