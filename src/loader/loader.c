/*
 * loader.c
 *
 * 유저스페이스에서 실행되는 로더. 세 가지 일을 한다.
 *   1) eBPF 프로그램을 커널에 올리고(load) 후킹 지점에 연결(attach)한다.
 *      이 과정에서 session_cgroups map이 /sys/fs/bpf/ 에 pin 된다.
 *   2) ring buffer에서 이벤트를 꺼내 JSON 한 줄로 출력한다.
 *   3) 종료 신호(Ctrl+C 등)를 받을 때까지 살아 있는다.
 *      (로더가 종료되면 프로그램이 detach 되어 감시가 멈춘다)
 *
 * 반드시 agent-run 보다 먼저 실행해 둘 것 (map 이 있어야 cgroup id 등록이 된다).
 *
 * 빌드:
 *   gcc -Wall -o myc_loader loader/loader.c -I. -lbpf -lelf -lz
 * 실행:
 *   sudo ./myc_loader | tee /tmp/events.jsonl
 */
#include <stdio.h>
#include <signal.h>
#include <linux/types.h>         /* event.h 의 __u32/__u64 제공. event.h 보다 먼저! */
#include <bpf/libbpf.h>
#include "watcher.skel.h"        /* bpftool 이 생성한 skeleton (바이트코드 내장) */
#include "bpf/event.h"           /* 커널과 공유하는 이벤트 형식 */

/* 시그널 핸들러가 바꾸는 종료 플래그. 시그널 안전을 위해 volatile sig_atomic_t */
static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

/*
 * ring buffer에서 이벤트 한 개를 꺼낼 때마다 ring_buffer__poll()이 호출하는 콜백.
 * poll을 호출한 같은 스레드에서 실행되므로 여기서 오래 걸리는 일을 하면
 * 다음 이벤트 처리가 늦어져 ring buffer가 차고 이벤트가 유실될 수 있다.
 *   data : 이벤트 시작 주소 (event_hdr로 시작)
 *   len  : 이벤트 바이트 길이
 * 반환값: 0 = 계속, 음수 = poll 중단
 */
static int handle_event(void *ctx, void *data, size_t len)
{
    /* 먼저 공통 헤더만 읽어 kind 로 종류를 판별 */
    const struct event_hdr *h = data;

    if (h->kind == EVT_EXEC) {
        const struct evt_exec *e = data;   /* 헤더가 첫 필드이므로 같은 주소를 캐스팅 */

        /*
         * TODO(금요일 이후): filename 에 따옴표/제어문자가 있으면 JSON 이 깨진다.
         * 보안 도구에서는 로그 위조 경로가 되므로 이스케이프 처리 필요.
         */
        printf("{\"kind\":\"EXEC\",\"pid\":%u,\"cgroup_id\":%llu,"
               "\"ts_ns\":%llu,\"filename\":\"%s\"}\n",
               h->pid,
               (unsigned long long)h->cgroup_id,
               (unsigned long long)h->ts_ns,
               e->filename);
        fflush(stdout);   /* 파이프(tee)로 보낼 때 지연 없이 바로 나가게 */
    }
    return 0;
}

int main(void)
{
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    /* ---- skeleton 으로 eBPF 프로그램 올리기 ---- */
    struct watcher_bpf *skel = watcher_bpf__open();   /* 내장된 오브젝트를 열기 */
    if (!skel) return 1;
    if (watcher_bpf__load(skel)) return 1;            /* 커널에 로드: map 생성, verifier 검증, pin */
    if (watcher_bpf__attach(skel)) return 1;          /* tracepoint 에 연결: 이 시점부터 이벤트 발생 */

    /* ---- ring buffer 소비자 만들기 ---- */
    struct ring_buffer *rb = ring_buffer__new(
        bpf_map__fd(skel->maps.events),   /* skeleton 필드 = watcher.bpf.c 의 map 이름 */
        handle_event,                     /* 이벤트마다 호출할 콜백 */
        NULL, NULL);
    if (!rb) return 1;

    fprintf(stderr, "[loader] ready\n");   /* stderr 로 출력해 JSON 출력과 섞이지 않게 */

    /* 최대 100ms 대기 -> 이벤트가 있으면 handle_event() 호출. 종료 플래그가 설 때까지 반복 */
    while (!stop)
        ring_buffer__poll(rb, 100);

    /* 정리: ring buffer 해제 후 프로그램 detach/unload */
    ring_buffer__free(rb);
    watcher_bpf__destroy(skel);
    return 0;
}
