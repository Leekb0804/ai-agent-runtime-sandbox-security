/*
 * kill.c
 *
 * kill switch 스텁. 실제로는 아무 프로세스도 죽이지 않는다.
 * 3주차에 이 함수의 본문을 실제 종료 로직으로 바꾼다 (인터페이스는 kill.h 참고).
 */
#include <stdio.h>
#include "kill.h"

int kill_session(struct session *s, const char *reason)
{
    /*
     * 판정과 같은 파일(verdicts.jsonl)에 type=action 레코드로 남겨서 "판정 -> 대응" 순서가 한눈에 보이게 한다.
     * 한 세션에서 BLOCK 이 여러 번 나와도 이 줄은 한 번만 기록된다 (호출하는 쪽이 보장).
     */
    session_write_action(s, "would_kill", reason);

    /*
     * 화면 알림은 stderr 로 낸다. stdout 은 JSON 로그용으로 남겨 두어 파이프(| tee)로 받을 때
     * 사람이 읽는 알림이 JSON 줄 사이에 섞이지 않게 하려는 것이다.
     */
    fprintf(stderr, "[kill-stub] 세션 %s (cgroup %llu) 를 종료했을 것: %s\n",
            s->id, (unsigned long long)s->cgroup_id, reason ? reason : "");
    return 0;
}
