/*
 * loader.c
 *
 * ===== 이 파일의 역할 =====
 * 유저스페이스 로더(메인 프로그램). 이 프로그램은 "세션"이 아니라 세션들을 바깥에서 지켜보는 감시자이다.
 * 세션과 무관하게 계속 떠 있으면서 여러 세션의 이벤트를 받아 세션별 폴더로 나눠 기록한다.
 *
 *     [호스트]
 *       myc_loader (감시자, 계속 떠 있음) --- 세션 A (컨테이너, 에이전트가 돌아감)
 *                                         \-- 세션 B (컨테이너, 에이전트가 돌아감)
 *
 * 하는 일:
 *   1) eBPF 프로그램을 커널에 올리고(load) 후킹 지점에 연결(attach)한다.
 *   2) ring buffer 에서 이벤트를 꺼내 세션별 events.jsonl 에 기록하고 디스패처에 넘긴다.
 *   3) 판정이 나오면 handle_verdict 가 verdicts.jsonl 에 기록하고, BLOCK 이면 kill 스텁을 호출한다.
 *   4) Ctrl+C / SIGTERM 을 받으면 로그 통계를 출력하고 정리한 뒤 종료한다.
 *
 * ===== 4일차에서 바뀐 점 =====
 *   - 화면에만 찍던 이벤트/판정을 세션 로그 파일에도 기록한다 (화면 출력은 개발 확인용으로 유지)
 *   - 판정 처리가 print_verdict(출력만) 에서 handle_verdict(기록 + 대응)로 바뀐다
 *   - 출력 형식은 jsonl.c 한 곳에서 만든다 (화면과 파일이 같은 형식)
 *
 * ===== 전체 흐름 =====
 *   ring buffer -> handle_event -> session_get(cgroup_id) -> events.jsonl + 화면
 *                               -> dispatch_event -> 탐지기들 -> handle_verdict
 *                                                       -> verdicts.jsonl (+ BLOCK 이면 kill_session 스텁)
 *
 * 실행: sudo ./myc_loader [세션 루트 디렉토리]
 *       (생략하면 /var/lib/mycontainer/sessions)
 * 이 로더는 agent-run 보다 먼저 떠 있어야 한다 (session_cgroups map 이 있어야 cgroup 등록이 된다).
 */
#include <stdio.h>
#include <signal.h>
#include <linux/types.h>         /* event.h 의 __u32/__u64 제공. event.h 보다 먼저 include! */
#include <bpf/libbpf.h>          /* ring_buffer__*, bpf_map__fd */
#include "watcher.skel.h"        /* bpftool 이 생성한 skeleton */
#include "bpf/event.h"
#include "detector.h"
#include "dispatcher.h"
#include "jsonl.h"
#include "session_log.h"
#include "verdict_handler.h"

#define DEFAULT_SESSIONS_ROOT "/var/lib/mycontainer/sessions"

/*
 * 종료 플래그. 시그널 핸들러가 세우고 메인 루프가 읽는다 (volatile sig_atomic_t 관용구).
 * 핸들러 안에서는 플래그만 세우고, printf/free 같은 정리는 루프를 빠져나온 뒤 일반 코드에서 한다.
 */
static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

/*
 * ring buffer 콜백. 이벤트마다 호출된다. 이 함수가 느려지면 ring buffer 가 가득 차서
 * 커널 쪽에서 이벤트가 유실되므로, 하는 일을 최소한으로 둔다.
 *   data : 이벤트 시작 주소 (ring buffer 공유 메모리를 직접 가리킨다. 콜백이 끝나면 재사용됨)
 *   len  : 이벤트의 바이트 수
 */
static int handle_event(void *ctx, void *data, size_t len)
{
    (void)ctx;
    if (len < sizeof(struct event_hdr))
        return 0;

    const struct event_hdr *h = data;

    /* 이 이벤트가 어느 세션의 것인지 찾고, 그 세션의 events.jsonl 에 기록 */
    struct session *s = session_get(h->cgroup_id);
    session_write_event(s, h, len);

    /*
     * 개발 중 확인용으로 화면에도 출력 (같은 형식).
     * fflush 이유: 파이프(| tee)로 실행하면 stdout 이 블록 버퍼링이라 이벤트가 한참 뒤에야 나타난다.
     * 이벤트가 매우 많아지면 매번 flush 하는 비용이 문제될 수 있어서, 나중에 화면 출력을 끄는 옵션을 고려할 만하다.
     */
    jsonl_write_event(stdout, s->id, h, len);
    fflush(stdout);

    dispatch_event(data, len);    /* 탐지기에게 분배. 판정이 나오면 handle_verdict 가 호출됨 */
    return 0;
}

int main(int argc, char **argv)
{
    /* 첫 번째 인자가 있으면 세션 폴더의 부모 경로로 쓴다. 테스트에서 다른 경로를 쓰려는 용도이다. */
    const char *root = (argc > 1) ? argv[1] : DEFAULT_SESSIONS_ROOT;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    session_log_init(root);

    /*
     * 판정 처리 함수를 등록. 두 번째 인자 stdout 은 ctx 로 보관되었다가 판정이 날 때마다
     * handle_verdict 의 ctx 로 그대로 돌아온다 (판정을 화면에도 출력하라는 뜻).
     * 탐지기들은 main() 이전에 각자의 생성자가 이미 등록해 두었다.
     */
    dispatcher_set_sink(handle_verdict, stdout);

    struct watcher_bpf *skel = watcher_bpf__open();
    if (!skel) return 1;
    if (watcher_bpf__load(skel)) return 1;
    if (watcher_bpf__attach(skel)) return 1;

    struct ring_buffer *rb = ring_buffer__new(
        bpf_map__fd(skel->maps.events), handle_event, NULL, NULL);
    if (!rb) return 1;

    fprintf(stderr, "[loader] ready (sessions root: %s)\n", root);

    /* 최대 100ms 대기하다가 이벤트가 있으면 handle_event 호출. stop 플래그가 설 때까지 반복 */
    while (!stop)
        ring_buffer__poll(rb, 100);

    /*
     * 종료 전에 로그 쓰기 통계를 알린다. slow 나 lost 가 0 이 아니면
     * 로그 쓰기가 수신 루프를 늦추거나 기록을 잃은 것이므로 확인이 필요하다.
     */
    const struct session_log_stats *st = session_log_get_stats();
    fprintf(stderr, "[loader] log stats: writes=%lu slow(>5ms)=%lu max=%lluus lost=%lu\n",
            st->writes, st->slow_writes, st->max_ns / 1000ULL, st->lost);

    /* 루프를 빠져나온 뒤의 일반 코드 흐름이므로 정리 함수를 호출해도 안전하다 */
    ring_buffer__free(rb);
    watcher_bpf__destroy(skel);
    session_log_close_all();      /* 열려 있는 모든 세션의 로그 파일을 닫는다 */
    return 0;
}
