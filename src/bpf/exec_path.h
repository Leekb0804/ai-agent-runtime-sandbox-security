/*
 * exec_path.h
 * 역할: 세션 cgroup 안의 exec 마다 실행 파일의 요청 이름과 최종 dentry 이름(부모, 조부모 포함)을
 *       EVT_EXEC_PATH 로 ring buffer 에 보낸다. 판정은 하지 않는다 (탐지기 exec_identity 의 입력).
 * watcher.bpf.c 의 session_cgroups, events, count_drop 을 쓰므로 watcher.bpf.c 끝에서 include 한다.
 * bpf_d_path 는 이 훅에서 허용되지 않아 (bpftrace: helper bpf_d_path not allowed in probe)
 * 경로 전체 대신 dentry 이름을 BPF_CORE_READ 로 고정된 세 단계만 읽는다.
 */
#ifndef EXEC_PATH_H
#define EXEC_PATH_H

#include <bpf/bpf_tracing.h>     /* BPF_PROG: fentry 프로그램의 인자를 받는 매크로 */
#include <bpf/bpf_core_read.h>   /* BPF_CORE_READ: 커널 구조체 필드를 안전하게 읽는 매크로 */

/*
 * dentry 하나의 이름을 dst 에 복사한다. dentry 나 이름 포인터가 NULL 이면 빈 문자열로 둔다.
 * bpf_probe_read_kernel_str 는 실패하면 dst 를 0 으로 채우므로 그때도 빈 문자열이 된다.
 * size 는 호출하는 쪽에서 상수로 넘긴다 (verifier 가 크기를 알아야 한다).
 */
static __always_inline void read_dname(char *dst, __u32 size, struct dentry *d)
{
    dst[0] = '\0';                                       /* 기본값: 빈 문자열 */
    if (!d)                                              /* 위 단계에서 dentry 를 못 얻음 */
        return;
    const unsigned char *name = BPF_CORE_READ(d, d_name.name);   /* struct qstr 의 이름 포인터 */
    if (!name)                                           /* 이름 포인터가 없음 */
        return;
    bpf_probe_read_kernel_str(dst, size, name);          /* 커널 메모리 문자열 복사 (NUL 종료, 길면 잘림) */
}

/*
 * security_bprm_check 진입 시점에 호출된다. tag_hit.h 의 on_bprm_check 와 같은 함수에 붙는 두 번째 fentry 다.
 * 이 훅은 호스트의 모든 exec 가 지나므로 세션 검사를 맨 앞에 두고, 세션 밖이면 ring buffer 를 건드리기 전에 끝낸다.
 * 스크립트는 두 번 불린다: 첫 호출의 bprm->file 은 스크립트, 둘째는 인터프리터.
 */
SEC("fentry/security_bprm_check")
int BPF_PROG(on_exec_path, struct linux_binprm *bprm)
{
    /* exec 하는 프로세스가 속한 cgroup id */
    __u64 cg = bpf_get_current_cgroup_id();

    /* 감시 대상이 아니면 즉시 종료. 예약 전에 걸러야 호스트의 exec 가 버퍼를 채우지 않는다 */
    if (!bpf_map_lookup_elem(&session_cgroups, &cg))
        return 0;

    /* 이벤트 한 개 분량 예약. 가득 차면 버리고 센다 */
    struct evt_exec_path *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        count_drop(DROP_EXEC_PATH);   /* 가득 차서 버려짐: 센다 */
        return 0;
    }

    /* 공통 헤더 (EXEC 과 같은 의미: cgroup_id 는 exec 한 프로세스의 cgroup) */
    e->hdr.kind = EVT_EXEC_PATH;
    e->hdr.pid = bpf_get_current_pid_tgid() >> 32;          /* 상위 32비트 = tgid */
    e->hdr.cgroup_id = cg;
    e->hdr.ts_ns = bpf_ktime_get_ns();
    e->hdr.payload_len = sizeof(*e) - sizeof(e->hdr);       /* 헤더 뒤 payload 길이 (TAG_HIT 과 같은 계산) */
    e->hdr._pad = 0;

    /* 요청 이름: bprm->filename 은 커널 메모리의 문자열 (tag_hit.h 와 같은 방식) */
    bpf_probe_read_kernel_str(e->filename, sizeof(e->filename),
                              BPF_CORE_READ(bprm, filename));

    /* 최종 파일의 dentry. 커널이 링크를 다 따라간 뒤의 파일이다 */
    struct dentry *d = BPF_CORE_READ(bprm, file, f_path.dentry);
    read_dname(e->final_name, sizeof(e->final_name), d);

    /* 부모 dentry. 반복문 대신 단계마다 펼쳐 쓴다 (verifier 부담을 줄이려고) */
    d = d ? BPF_CORE_READ(d, d_parent) : NULL;
    read_dname(e->parent_name, sizeof(e->parent_name), d);

    /* 조부모 dentry */
    d = d ? BPF_CORE_READ(d, d_parent) : NULL;
    read_dname(e->grandparent_name, sizeof(e->grandparent_name), d);

    /* 예약한 공간을 확정 -> 유저스페이스가 읽을 수 있게 됨 */
    bpf_ringbuf_submit(e, 0);
    return 0;
}

#endif /* EXEC_PATH_H */
