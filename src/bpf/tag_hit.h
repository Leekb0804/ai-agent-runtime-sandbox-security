/*
 * tag_hit.h
 * 역할: exec 되는 파일이 write_tags 에 있으면 (= 세션 cgroup 이 쓴 파일) EVT_TAG_HIT 를 ring buffer 로 보낸다.
 * write_tag.h 의 write_tags 맵과 watcher.bpf.c 의 events 맵을 쓰므로 watcher.bpf.c 끝에서 include 한다.
 * 이 단계는 이벤트만 올리고 판정은 하지 않는다. 만료(10분)도 아직 없다.
 */
#ifndef TAG_HIT_H
#define TAG_HIT_H

#include "write_tag.h"

/*
 * security_bprm_check 진입 시점에 호출된다. 호스트의 모든 exec 가 지나므로 (세션 밖 exec 도 봐야 하므로
 * session_cgroups 로 거르지 않는다) 맵 조회에서 miss 나면 바로 끝내 가볍게 유지한다.
 * 스크립트는 이 훅이 두 번 불린다: 첫 호출이 스크립트 파일, 둘째가 인터프리터 (bpftrace 로 확인).
 */
SEC("fentry/security_bprm_check")
int BPF_PROG(on_bprm_check, struct linux_binprm *bprm)
{
    /* 실행 대상 파일의 신원: bprm->file->f_inode 의 s_dev 와 i_ino */
    struct file_id id = {};
    id.dev = BPF_CORE_READ(bprm, file, f_inode, i_sb, s_dev);
    id.ino = BPF_CORE_READ(bprm, file, f_inode, i_ino);

    /* 태그가 없으면 (대부분의 exec) 여기서 끝 */
    struct write_tag *t = bpf_map_lookup_elem(&write_tags, &id);
    if (!t)
        return 0;

    /* 이벤트 한 개 분량 예약. 가득 차면 이 히트는 유실된다 (drop_counts 로 센다) */
    struct evt_tag_hit *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        count_drop(DROP_TAG_HIT);   /* 가득 차서 버려짐: 센다 */
        return 0;
    }

    /* 헤더: cgroup_id 는 태그 소유 세션, pid 는 exec 한 프로세스 (event.h 의 예외 규칙) */
    e->hdr.kind = EVT_TAG_HIT;
    e->hdr.pid = bpf_get_current_pid_tgid() >> 32;
    e->hdr.cgroup_id = t->cgroup_id;
    e->hdr.ts_ns = bpf_ktime_get_ns();
    e->hdr.payload_len = sizeof(*e) - sizeof(e->hdr);
    e->hdr._pad = 0;

    /* payload */
    e->exec_cgroup_id = bpf_get_current_cgroup_id();
    e->tag_ts_ns = t->ts_ns;
    e->tag_write_count = t->write_count;
    e->dev = id.dev;
    e->_pad = 0;
    e->ino = id.ino;
    /* bprm->filename 은 커널 메모리의 문자열이므로 probe_read_kernel_str 로 복사 */
    bpf_probe_read_kernel_str(e->filename, sizeof(e->filename),
                              BPF_CORE_READ(bprm, filename));

    bpf_ringbuf_submit(e, 0);
    return 0;
}

#endif /* TAG_HIT_H */
