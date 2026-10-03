/*
 * jsonl.c
 *
 * JSON Lines 레코드 생성. 레코드 하나는 항상 "\n" 으로 끝나는 한 줄이다.
 *
 * 한 줄은 이런 조각들이 f 에 차례로 붙어서 완성된다 (verdict 의 경우).
 *
 *   put_head           {"schema_version":0,"type":"verdict","session":"...","logged_at_ms":...
 *   fprintf/fputs      ,"level":"BLOCK","detector":"...","reason":"..."
 *   put_event_obj      ,"event":{"kind":"EXEC","pid":...,"filename":"..."}
 *   fputs("}\n")       }  와 줄바꿈
 *
 * 공통 머리(head)에는 이런 필드가 들어간다.
 *   schema_version : 로그 형식 버전 (지금은 0 = 초안)
 *   type           : event / verdict / action
 *   session        : 세션 ID. 레코드마다 직접 넣는 이유는 cgroup ID 가 세션이 끝나면 사라지기 때문이다
 *   logged_at_ms   : 로그를 "쓴" 시각 (벽시계, epoch 밀리초)
 *
 * 주의: logged_at_ms 는 이벤트가 발생한 시각이 아니라 기록한 시각이다.
 *       이벤트 발생 시각은 event.ts_ns (부팅 후 경과 나노초, 단조 시계)이며,
 *       두 시계를 정확히 맞추는 일은 5주차 로그 스키마 확정 때 한다.
 */
#include <time.h>
#include "jsonl.h"
#include "json_escape.h"
#include "dispatcher.h"           /* verdict_level_str */

/* 현재 벽시계 시각을 epoch 밀리초로 */
static unsigned long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (unsigned long long)ts.tv_sec * 1000ULL + (unsigned long long)ts.tv_nsec / 1000000ULL;
}

/* 이벤트 종류 번호를 문자열로. 모르는 번호는 "UNKNOWN". */
static const char *kind_str(__u32 kind)
{
    switch (kind) {
    case EVT_EXEC:  return "EXEC";
    case EVT_WRITE: return "WRITE";
    case EVT_OPEN:  return "OPEN";
    case EVT_DNS:   return "DNS";
    default:        return "UNKNOWN";
    }
}

/*
 * "event": {...} 에 들어갈 객체를 쓴다.
 * %llu 에 맞추려고 __u64 를 (unsigned long long)으로 캐스팅한다
 * (플랫폼마다 __u64 의 실제 타입이 달라 경고가 나는 것을 막음).
 * EXEC 이벤트는 길이가 충분할 때만 filename 을 읽는다 (구조체 끝을 넘어 읽지 않도록).
 * filename 은 에이전트가 정할 수 있는 값이라 반드시 json_put_string 으로 이스케이프한다.
 */
static void put_event_obj(FILE *f, const struct event_hdr *h, size_t len)
{
    fprintf(f, "{\"kind\":\"%s\",\"pid\":%u,\"cgroup_id\":%llu,\"ts_ns\":%llu",
            kind_str(h->kind), h->pid,
            (unsigned long long)h->cgroup_id, (unsigned long long)h->ts_ns);

    if (h->kind == EVT_EXEC && len >= sizeof(struct evt_exec)) {
        const struct evt_exec *e = (const struct evt_exec *)h;
        fputs(",\"filename\":", f);
        json_put_string(f, e->filename, MAX_FILENAME);   /* 공격자가 정할 수 있는 값 */
    }
    fputc('}', f);
}

/* 모든 레코드가 공유하는 머리. 닫는 중괄호는 쓰지 않는다 (뒤에 필드가 이어짐). */
static void put_head(FILE *f, const char *type, const char *session)
{
    fprintf(f, "{\"schema_version\":%d,\"type\":\"%s\",\"session\":",
            LOG_SCHEMA_VERSION, type);
    json_put_string(f, session, 128);
    fprintf(f, ",\"logged_at_ms\":%llu", now_ms());
}

/* event 레코드: 머리 + "event":{...} + 줄 끝 */
void jsonl_write_event(FILE *f, const char *session,
                       const struct event_hdr *h, size_t len)
{
    put_head(f, "event", session);
    fputs(",\"event\":", f);
    put_event_obj(f, h, len);
    fputs("}\n", f);
}

/* verdict 레코드: 머리 + 수준, 탐지기 이름, 이유 + 원인이 된 "event":{...} + 줄 끝 */
void jsonl_write_verdict(FILE *f, const char *session,
                         const struct event_hdr *h, size_t len,
                         const struct verdict *v)
{
    put_head(f, "verdict", session);
    fprintf(f, ",\"level\":\"%s\",\"detector\":", verdict_level_str(v->level));
    json_put_string(f, v->detector ? v->detector : "", 64);
    fputs(",\"reason\":", f);
    json_put_string(f, v->reason, sizeof(v->reason));
    fputs(",\"event\":", f);
    put_event_obj(f, h, len);
    fputs("}\n", f);
}

/*
 * action 레코드: 머리 + 대상 cgroup, 대응 이름, 이유 + 줄 끝.
 * 대응(예: would_kill)은 이벤트가 아니라 판정에 따른 결과라서 event 객체가 없고 cgroup_id 를 직접 넣는다.
 */
void jsonl_write_action(FILE *f, const char *session, __u64 cgroup_id,
                        const char *action, const char *reason)
{
    put_head(f, "action", session);
    fprintf(f, ",\"cgroup_id\":%llu,\"action\":", (unsigned long long)cgroup_id);
    json_put_string(f, action, 64);
    fputs(",\"reason\":", f);
    json_put_string(f, reason ? reason : "", 128);
    fputs("}\n", f);
}
