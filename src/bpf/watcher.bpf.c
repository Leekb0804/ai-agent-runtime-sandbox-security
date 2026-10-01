/*
 * watcher.bpf.c
 *
 * 커널 안에서 실행되는 eBPF 프로그램.
 * 역할: 감시 대상 cgroup(session_cgroups에 등록된 것)에서 execve가 일어나면
 *       이벤트를 만들어 ring buffer(events)로 보낸다. 판정은 하지 않고 관측만 한다.
 *
 * 빌드:
 *   clang -g -O2 -target bpf -D__TARGET_ARCH_arm64 -I bpf -c bpf/watcher.bpf.c -o watcher.bpf.o
 *   bpftool gen skeleton watcher.bpf.o > watcher.skel.h
 *
 * include 순서 주의: vmlinux.h 를 가장 먼저 (다른 커널 헤더와 같이 쓰면 타입 중복 에러)
 */
#include "vmlinux.h"             /* 커널 구조체/기본 타입 (__u32 등) */
#include <bpf/bpf_helpers.h>     /* SEC(), bpf_map_lookup_elem() 등 헬퍼 */
#include "event.h"               /* 로더와 공유하는 이벤트 형식 */

/* 커널에 로드하려면 GPL 호환 라이선스 표기가 필요하다 (GPL 전용 헬퍼 사용 때문) */
char LICENSE[] SEC("license") = "GPL";

/*
 * 감시 대상 cgroup 목록.
 *   key   : cgroup id (__u64)
 *   value : 의미 없는 1바이트 (등록 여부만 중요)
 * mycontainer_run.c 가 컨테이너 시작 전에 여기에 id를 넣고, 종료 후 뺀다.
 * LIBBPF_PIN_BY_NAME : 로드 시 /sys/fs/bpf/session_cgroups 로 자동 pin 되어
 *                      다른 프로세스(mycontainer_run)가 bpf_obj_get()으로 열 수 있다.
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u64);
    __type(value, __u8);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} session_cgroups SEC(".maps");

/*
 * 커널 -> 유저스페이스 이벤트 전달용 ring buffer.
 * max_entries 는 바이트 크기(256KB). 가득 차면 reserve가 실패해 이벤트가 유실된다.
 */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

/*
 * execve 시스템콜 진입 시점에 호출되는 tracepoint 프로그램.
 * (프로그램이 "attach"되면 이 이벤트가 발생할 때마다 커널이 이 함수를 호출한다)
 * ctx->args[0] 은 execve의 첫 인자(실행할 파일 경로, 유저 메모리 포인터).
 */
SEC("tracepoint/syscalls/sys_enter_execve")
int on_execve(struct trace_event_raw_sys_enter *ctx)
{
    /* 지금 syscall을 호출한 프로세스가 속한 cgroup id */
    __u64 cg = bpf_get_current_cgroup_id();

    /* 감시 대상이 아니면 즉시 종료. 호스트의 모든 exec가 여기를 지나므로 가볍게 끝나야 한다. */
    if (!bpf_map_lookup_elem(&session_cgroups, &cg))
        return 0;

    /* ring buffer에 이벤트 한 개 분량을 예약. 실패(가득 참)하면 이벤트를 버린다. */
    struct evt_exec *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    /* 공통 헤더 채우기 */
    e->hdr.kind = EVT_EXEC;
    e->hdr.pid = bpf_get_current_pid_tgid() >> 32;   /* 상위 32비트 = tgid */
    e->hdr.cgroup_id = cg;
    e->hdr.ts_ns = bpf_ktime_get_ns();
    e->hdr.payload_len = sizeof(e->filename);

    /* payload: 유저 메모리의 파일 경로 문자열을 복사 (NUL 종료, 길면 잘림) */
    bpf_probe_read_user_str(e->filename, sizeof(e->filename),
                            (void *)ctx->args[0]);

    /* 예약한 공간을 확정 -> 유저스페이스가 읽을 수 있게 됨 */
    bpf_ringbuf_submit(e, 0);
    return 0;
}
