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
 *   3) 판정이 나오면 handle_verdict 가 verdicts.jsonl 에 기록하고, BLOCK 이면 kill_session 으로 세션 cgroup 을 종료한다.
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
 *                                                       -> verdicts.jsonl (+ BLOCK 이면 kill_session)
 *
 * 실행: sudo ./myc_loader [세션 루트 디렉토리] [--detectors=이름,이름,...] [--no-kill]
 *       세션 루트를 생략하면 /var/lib/mycontainer/sessions. 옵션과 세션 루트의 순서는 상관없다.
 *       --detectors 를 생략하면 시험용(test_only)이 아닌 탐지기만 켠다. 더미 탐지기는 이름으로 명시해야 켜진다
 *       (예: 러너는 --detectors=dummy_block,dummy_suspect,write_exec_boundary).
 *       --no-kill 은 관찰 모드(평가용)이다. BLOCK 이어도 세션을 종료하지 않고 action="would_kill" 만 기록한다 (kill.h).
 *       러너는 이 옵션을 쓰지 않는다.
 *       잘못된 인자(모르는 옵션, 모르는 탐지기 이름 등)는 BPF 를 올리기 전에 거부하고 종료 코드 2 로 끝난다.
 *       준비되면 stderr 에 "[loader] ready (sessions root: <루트>, mode: <kill|observe>, detectors: <알파벳순 목록>)" 를 낸다.
 * 이 로더는 agent-run 보다 먼저 떠 있어야 한다 (session_cgroups map 이 있어야 cgroup 등록이 된다).
 */
#include <stdio.h>
#include <signal.h>
#include <linux/types.h>         /* event.h 의 __u32/__u64 제공. event.h 보다 먼저 include! */
#include <bpf/libbpf.h>          /* ring_buffer__*, bpf_map__fd */
#include <bpf/bpf.h>             /* bpf_map_lookup_elem, bpf_map_delete_elem */
#include <stdlib.h>              /* calloc, free */
#include <errno.h>
#include <string.h>              /* strerror */
#include "watcher.skel.h"        /* bpftool 이 생성한 skeleton */
#include "bpf/event.h"
#include "detector.h"
#include "dispatcher.h"
#include "jsonl.h"
#include "session_log.h"
#include "verdict_handler.h"
#include "kill.h"
#include "loader_lock.h"
#include "loader_args.h"

#define DEFAULT_SESSIONS_ROOT "/var/lib/mycontainer/sessions"
#define USAGE "사용법: myc_loader [세션 루트] [--detectors=이름,이름,...] [--no-kill]"

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

/*
 * kill 이 cgroup.kill 에 쓴(sent) 뒤 불리는 콜백. 그 cgroup 을 session_cgroups 맵에서 지운다.
 * 관리자(mycontainer_run)가 함께 죽어서 스스로 지우지 못하기 때문이다. ctx 는 맵 fd 를 담은 int 의 주소다.
 * 항목이 이미 없으면(ENOENT) 지워진 것과 같으므로 성공으로 본다. 맵을 다루는 libbpf 호출은 이 파일에만 둔다.
 */
static int unwatch_cgroup(__u64 cgroup_id, void *ctx)
{
    int fd = *(const int *)ctx;
    if (bpf_map_delete_elem(fd, &cgroup_id) == 0 || errno == ENOENT)
        return 0;
    fprintf(stderr, "[loader] session_cgroups 항목 삭제 실패 (cgroup %llu): %s\n",
            (unsigned long long)cgroup_id, strerror(errno));
    return -1;
}

/*
 * 커널 쪽에서 ring buffer 가 가득 차서 버려진 이벤트 수를 읽어 한 줄로 알린다.
 * drop_counts 는 CPU 마다 따로 센 값을 담고 있어서, CPU 개수만큼 읽어 합친다.
 * 읽지 못하면 0 으로 보이지 않게 "확인 실패"로 출력한다 (0 과 모름을 구분하기 위해).
 */
static void report_drops(struct watcher_bpf *skel)
{
    int ncpu = libbpf_num_possible_cpus();                       /* 가능한 CPU 개수 */
    __u64 *vals = (ncpu > 0) ? calloc((size_t)ncpu, sizeof(__u64)) : NULL;   /* CPU별 값을 받을 배열 */
    __u64 sum[DROP_KIND_MAX] = {0};                              /* 종류별 합계 */
    int ok = (vals != NULL);

    for (__u32 k = 0; ok && k < DROP_KIND_MAX; k++) {
        /* percpu 맵은 key 하나를 읽으면 CPU 개수만큼의 값이 한꺼번에 vals 에 채워진다 */
        if (bpf_map_lookup_elem(bpf_map__fd(skel->maps.drop_counts), &k, vals) != 0) {
            ok = 0;
            break;
        }
        for (int i = 0; i < ncpu; i++)
            sum[k] += vals[i];
    }

    if (ok)
        fprintf(stderr, "[loader] ring buffer drops: exec=%llu tag_hit=%llu\n",
                (unsigned long long)sum[DROP_EXEC], (unsigned long long)sum[DROP_TAG_HIT]);
    else
        fprintf(stderr, "[loader] ring buffer drops: 확인 실패\n");
    free(vals);
}

int main(int argc, char **argv)
{
    /*
     * 인자 해석과 탐지기 선택은 BPF 로드, pin, 잠금보다 먼저 한다.
     * 잘못된 인자면 아무것도 건드리지 않고 끝난다 (세션 폴더도 만들지 않는다).
     */
    static struct loader_args args;
    char err[256];
    if (loader_parse_args(argc, argv, &args, err, sizeof(err)) != 0) {
        fprintf(stderr, "[loader] 인자 오류: %s\n%s\n", err, USAGE);
        return 2;
    }
    /* 세션 루트가 있으면 세션 폴더의 부모 경로로 쓴다. 테스트에서 다른 경로를 쓰려는 용도이다. */
    const char *root = args.root ? args.root : DEFAULT_SESSIONS_ROOT;

    /* 탐지기 등록이 거부된 적이 있으면 감시 구성이 불완전하므로 시작하지 않는다 */
    if (dispatcher_registration_errors() != 0) {
        fprintf(stderr, "[loader] 탐지기 등록 오류 - 시작하지 않음\n");
        return 1;
    }
    /* 켤 탐지기를 고른다. --detectors 가 없으면 n_detectors 가 0 이라 기본 선택(시험용 제외)이 된다 */
    if (dispatcher_select(args.names, args.n_detectors, err, sizeof(err)) != 0) {
        fprintf(stderr, "[loader] 탐지기 선택 오류: %s\n%s\n", err, USAGE);
        return 2;
    }
    /* ready 줄에 찍을 목록 (알파벳순). 탐지기 16개 x 이름 63자 + 쉼표가 들어가는 크기 */
    static char detector_names[MAX_DETECTORS * LOADER_ARGS_NAME_MAX];
    if (dispatcher_selected_names(detector_names, sizeof(detector_names)) != 0) {
        fprintf(stderr, "[loader] 탐지기 목록을 만들지 못함 - 시작하지 않음\n");
        return 1;
    }
    /* 어떤 탐지기가 켜져 있는지 시작할 때 한 번 출력한다 */
    dispatcher_print_detectors(stderr);

    /* BLOCK 에 대한 대응 방식. --no-kill 이면 관찰 모드이고, 놓치기 쉬우므로 목록 바로 뒤에 눈에 띄게 알린다 */
    kill_set_mode(args.no_kill ? KILL_MODE_OBSERVE : KILL_MODE_KILL);
    if (args.no_kill)
        fprintf(stderr, "[loader] !!! 관찰 모드: BLOCK 이어도 세션을 종료하지 않는다 (평가용)\n");

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

    /* 로드 뒤에 맵 fd 가 생긴다. kill 이 sent 일 때 그 cgroup 을 감시 대상에서 지우도록 연결한다 */
    static int cgroups_fd;
    cgroups_fd = bpf_map__fd(skel->maps.session_cgroups);
    kill_set_unwatch(unwatch_cgroup, &cgroups_fd);
    if (watcher_bpf__attach(skel)) return 1;

    struct ring_buffer *rb = ring_buffer__new(
        bpf_map__fd(skel->maps.events), handle_event, NULL, NULL);
    if (!rb) return 1;

    /*
     * 준비 완료 표시: 후킹 연결과 ring buffer 생성이 끝난 뒤에 배타 잠금을 건다.
     * agent-run 은 이 잠금이 쥐어져 있을 때만 세션을 시작한다. 잠금 fd 는 프로세스가 끝날 때까지
     * 일부러 닫지 않는다 (정상 종료, 크래시, SIGKILL 어느 쪽이든 커널이 잠금을 푼다).
     * 로더가 이미 떠 있으면 여기서 실패하고 종료한다.
     */
    int lock_fd = myc_loader_lock_acquire(myc_loader_lock_path());
    if (lock_fd < 0) {
        perror("[loader] 잠금 획득 실패 (이미 실행 중인 로더가 있는지 확인)");
        return 1;
    }

    /* 러너가 이 줄의 mode 와 detectors 를 기대와 비교한다 (run_scenarios.sh). mode 는 위에서 정한 대응 방식이다 */
    fprintf(stderr, "[loader] ready (sessions root: %s, mode: %s, detectors: %s)\n",
            root, args.no_kill ? "observe" : "kill", detector_names);

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
    report_drops(skel);

    /* 루프를 빠져나온 뒤의 일반 코드 흐름이므로 정리 함수를 호출해도 안전하다 */
    ring_buffer__free(rb);
    watcher_bpf__destroy(skel);
    session_log_close_all();      /* 열려 있는 모든 세션의 로그 파일을 닫는다 */
    return 0;
}
