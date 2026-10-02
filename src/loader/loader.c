/*
 * loader.c
 *
 * ===== 이 파일의 역할 =====
 * 유저스페이스에서 실행되는 로더(메인 프로그램). 네 가지 일을 한다.
 *   1) eBPF 프로그램을 커널에 올리고(load) 후킹 지점에 연결(attach)한다.
 *      이때 session_cgroups map 이 /sys/fs/bpf/ 에 pin 되어 mycontainer_run 이 쓸 수 있게 된다.
 *   2) ring buffer 에서 이벤트를 꺼내 (a) 이벤트 JSON 한 줄을 출력하고
 *      (b) 디스패처에 넘긴다.
 *   3) 탐지기가 판정을 내면 print_verdict 가 판정 JSON 한 줄을 출력한다.
 *      (로그 파일 기록과 kill switch 호출은 4일차 작업)
 *   4) Ctrl+C / SIGTERM 을 받을 때까지 살아 있다가 정리하고 종료한다.
 *      로더가 종료되면 프로그램이 detach 되어 감시가 멈추므로 계속 떠 있어야 한다.
 *
 * ===== 전체 흐름 =====
 *   [커널] execve -> watcher.bpf.c -> ring buffer
 *   [유저] ring_buffer__poll -> handle_event -> print_event(이벤트 줄 출력)
 *                                            -> dispatch_event -> 탐지기들 -> print_verdict(판정 줄 출력)
 *
 * 빌드는 src/build.sh 참고. 실행: sudo ./myc_loader | tee /tmp/events.jsonl
 */
#include <stdio.h>
#include <signal.h>
#include <linux/types.h>         /* event.h 의 __u32/__u64 제공. event.h 보다 먼저 include! */
#include <bpf/libbpf.h>          /* ring_buffer__*, bpf_map__fd */
#include "watcher.skel.h"        /* bpftool 이 생성한 skeleton (eBPF 바이트코드와 전용 함수 내장) */
#include "bpf/event.h"           /* 커널과 공유하는 이벤트 형식 */
#include "detector.h"
#include "dispatcher.h"
#include "json_escape.h"

/*
 * 종료 플래그. 시그널 핸들러가 값을 바꾸고 메인 루프가 읽는다.
 *   volatile     : 컴파일러가 이 값을 레지스터에 캐싱하지 못하게 한다 (루프 밖에서 바뀔 수 있으므로)
 *   sig_atomic_t : 시그널 핸들러 안에서도 한 번에 안전하게 읽고 쓸 수 있는 정수 타입
 * 핸들러는 이 플래그만 세우고 끝낸다. printf, free 같은 함수는 핸들러 안에서 호출하면
 * 데드락이나 메모리 손상 위험이 있으므로 정리는 루프를 빠져나온 뒤 일반 코드에서 한다.
 */
static volatile sig_atomic_t stop;

/* 시그널 핸들러. 인자 s 에는 시그널 번호(SIGINT 면 2)가 들어오지만 쓰지 않는다. */
static void on_sig(int s) { (void)s; stop = 1; }

/*
 * 이벤트 한 개를 JSON 한 줄로 출력한다.
 * "type":"event" 를 붙여서 아래 판정 줄("type":"verdict")과 섞여 나와도 구분할 수 있게 한다.
 *
 * h 를 EXEC 구조체로 해석하기 전에 kind 와 길이를 모두 확인한다.
 * 파일 이름은 공격자가 정할 수 있는 값이므로 json_put_string 으로 이스케이프해서 출력한다.
 * %llu 는 unsigned long long 용 형식이라, __u64 를 (unsigned long long)으로 캐스팅해서 맞춘다
 * (플랫폼마다 __u64 의 실제 타입이 달라 경고가 나는 것을 막는다).
 */
static void print_event(const struct event_hdr *h, size_t len)
{
    if (h->kind == EVT_EXEC && len >= sizeof(struct evt_exec)) {
        const struct evt_exec *e = (const struct evt_exec *)h;

        printf("{\"type\":\"event\",\"kind\":\"EXEC\",\"pid\":%u,\"cgroup_id\":%llu,"
               "\"ts_ns\":%llu,\"filename\":",
               h->pid, (unsigned long long)h->cgroup_id, (unsigned long long)h->ts_ns);
        json_put_string(stdout, e->filename, MAX_FILENAME);   /* 로그 위조 방지 */
        printf("}\n");
        fflush(stdout);   /* 파이프(| tee)로 보낼 때 버퍼에 쌓이지 않고 바로 나가게 */
    }
}

/*
 * 판정 처리 함수(sink). dispatcher_set_sink 로 등록되어, 탐지기가 판정을 내릴 때마다 호출된다.
 * 지금은 JSON 한 줄을 출력하는 것이 전부다.
 *
 * TODO(w1d4): 세션 로그 파일에 기록하고, 판정이 BLOCK 이면 kill_session() 을 호출한다.
 *
 * ctx 는 등록할 때 넘긴 포인터인데 쓰지 않으므로 경고 방지용으로 (void) 처리했다.
 */
static void print_verdict(const struct event_hdr *h, size_t len,
                          const struct verdict *v, void *ctx)
{
    (void)ctx;

    printf("{\"type\":\"verdict\",\"level\":\"%s\",\"detector\":",
           verdict_level_str(v->level));
    json_put_string(stdout, v->detector, 64);
    printf(",\"reason\":");
    json_put_string(stdout, v->reason, sizeof(v->reason));
    printf(",\"pid\":%u,\"cgroup_id\":%llu,\"ts_ns\":%llu",
           h->pid, (unsigned long long)h->cgroup_id, (unsigned long long)h->ts_ns);

    /* EXEC 이벤트가 원인이면 어떤 파일이었는지도 함께 남긴다 */
    if (h->kind == EVT_EXEC && len >= sizeof(struct evt_exec)) {
        const struct evt_exec *e = (const struct evt_exec *)h;
        printf(",\"filename\":");
        json_put_string(stdout, e->filename, MAX_FILENAME);
    }
    printf("}\n");
    fflush(stdout);
}

/*
 * ring buffer 콜백. ring_buffer__poll() 이 이벤트를 하나 꺼낼 때마다 호출한다.
 *   data : 이벤트 시작 주소. 복사본이 아니라 ring buffer 공유 메모리를 직접 가리킨다.
 *   len  : 이벤트의 바이트 수
 * 반환값: 0 = 계속, 음수 = poll 중단
 *
 * 이 함수는 poll 을 호출한 같은 스레드에서 실행되므로 가볍게 유지해야 한다.
 * 오래 걸리면 ring buffer 가 가득 차서 커널 쪽에서 이벤트가 버려진다(유실).
 * 길이와 kind 의 검증은 dispatch_event 가 하므로, 여기서는 헤더를 읽을 수 있는지만 본다.
 */
static int handle_event(void *ctx, void *data, size_t len)
{
    (void)ctx;
    if (len < sizeof(struct event_hdr))
        return 0;

    print_event(data, len);       /* (a) 이벤트 줄 출력 */
    dispatch_event(data, len);    /* (b) 탐지기들에게 분배 -> 판정이 나오면 print_verdict */
    return 0;
}

int main(void)
{
    /* Ctrl+C(SIGINT)와 kill(SIGTERM)를 받으면 on_sig 가 stop 을 1 로 세우도록 등록 */
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    /*
     * 판정 처리 함수를 등록한다. 탐지기들은 이미 main() 이전에
     * 각자의 생성자 함수가 register_detector 로 등록해 두었다.
     */
    dispatcher_set_sink(print_verdict, NULL);

    /* ---- skeleton 으로 eBPF 프로그램을 커널에 올린다 ---- */
    struct watcher_bpf *skel = watcher_bpf__open();   /* 내장된 오브젝트를 연다 */
    if (!skel) return 1;
    if (watcher_bpf__load(skel)) return 1;            /* 커널에 로드: map 생성, verifier 검증, pin */
    if (watcher_bpf__attach(skel)) return 1;          /* tracepoint 에 연결: 이 시점부터 이벤트 발생 */

    /* ---- ring buffer 소비자 생성 ---- */
    struct ring_buffer *rb = ring_buffer__new(
        bpf_map__fd(skel->maps.events),   /* skeleton 필드 이름 = watcher.bpf.c 의 map 이름 */
        handle_event,                     /* 이벤트마다 호출할 콜백 */
        NULL, NULL);                      /* 콜백에 넘길 ctx 와 옵션(쓰지 않음) */
    if (!rb) return 1;

    /* 준비 완료 표시. stderr 로 내보내서 stdout 의 JSON 출력과 섞이지 않게 한다 */
    fprintf(stderr, "[loader] ready\n");

    /*
     * 메인 루프. poll 은 최대 100ms 대기하다가 이벤트가 있으면 handle_event 를 호출한다.
     * 이벤트가 없어도 100ms 마다 깨어나 stop 플래그를 확인하므로, 시그널이 와도
     * 늦어야 0.1초 안에 루프를 빠져나온다.
     */
    while (!stop)
        ring_buffer__poll(rb, 100);

    /* 루프를 빠져나온 뒤의 일반 코드 흐름이므로 정리 함수를 마음껏 호출해도 안전하다 */
    ring_buffer__free(rb);
    watcher_bpf__destroy(skel);       /* 프로그램 detach 및 해제 (pin 된 map 파일은 남는다) */
    return 0;
}
