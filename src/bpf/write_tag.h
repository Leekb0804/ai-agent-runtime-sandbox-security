/*
 * write_tag.h
 * 역할: 세션 cgroup 이 쓰기 모드로 연 파일의 신원 (s_dev, i_ino) 을 write_tags 맵에 기록한다 (태깅).
 * 이 단계는 태깅만 한다. exec 조회와 이벤트 emit 은 다음 단계에서 추가한다.
 * watcher.bpf.c 의 맨 끝에서 include 한다 (session_cgroups 맵이 먼저 정의되어 있어야 하므로).
 */
#ifndef WRITE_TAG_H
#define WRITE_TAG_H

#include <bpf/bpf_tracing.h>     /* BPF_PROG: fentry 프로그램의 인자를 받는 매크로 */
#include <bpf/bpf_core_read.h>   /* BPF_CORE_READ: 커널 구조체 필드를 안전하게 읽는 매크로 */

/* 쓰기 모드 비트. bpftrace 관측에서 쓰기 open 은 mode 끝자리 2, 읽기 open 은 1 이었다. */
#define MYC_FMODE_WRITE 0x2

/* 태그 맵 크기. 계획서 값 10240. overlay 에서는 파일 하나가 두 쌍으로 들어가 실효 용량은 절반이다. */
#define TAG_MAP_MAX 10240

/* 맵의 키: 파일의 신원. _pad 는 8바이트 정렬용 (키에 쓰레기 값이 섞이지 않게 명시한다) */
struct file_id {
    __u32 dev;      /* 슈퍼블록의 s_dev (파일시스템 번호) */
    __u32 _pad;
    __u64 ino;      /* inode 번호 */
};

/* 맵의 값: 누가, 언제, 몇 번 썼는가 */
struct write_tag {
    __u64 cgroup_id;     /* 마지막으로 쓴 세션 cgroup */
    __u64 ts_ns;         /* 마지막으로 쓴 시각 (bpf_ktime_get_ns) */
    __u64 write_count;   /* 쓰기 open 횟수 */
};

/*
 * 태그 맵. LRU_HASH 는 가득 차면 오래된 항목부터 자동으로 버린다.
 * pin 하지 않는다: 로더가 끝나면 맵도 사라져서 이전 실행의 태그가 남지 않는다.
 * 확인은 로더가 떠 있는 동안 bpftool 로 한다 (이름 write_tags).
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, TAG_MAP_MAX);
    __type(key, struct file_id);
    __type(value, struct write_tag);
} write_tags SEC(".maps");

/*
 * security_file_open 진입 시점에 호출된다. 호스트의 모든 파일 open 이 지나므로
 * 가장 싼 검사(세션 cgroup 여부)를 먼저 하고 일찍 반환한다.
 */
SEC("fentry/security_file_open")
int BPF_PROG(on_file_open, struct file *file)
{
    /* 지금 open 을 호출한 프로세스의 cgroup. 세션이 아니면 바로 종료 */
    __u64 cg = bpf_get_current_cgroup_id();
    if (!bpf_map_lookup_elem(&session_cgroups, &cg))
        return 0;

    /* 열기 모드에 쓰기 비트가 없으면 (읽기 open) 종료 */
    __u32 mode = BPF_CORE_READ(file, f_mode);
    if (!(mode & MYC_FMODE_WRITE))
        return 0;

    /* 파일 신원: file->f_inode->i_sb->s_dev 와 file->f_inode->i_ino */
    struct file_id id = {};
    id.dev = BPF_CORE_READ(file, f_inode, i_sb, s_dev);
    id.ino = BPF_CORE_READ(file, f_inode, i_ino);

    /* 이미 태그가 있으면 갱신: 소유 cgroup, 시각을 바꾸고 횟수를 1 늘린다 */
    struct write_tag *t = bpf_map_lookup_elem(&write_tags, &id);
    if (t) {
        t->cgroup_id = cg;
        t->ts_ns = bpf_ktime_get_ns();
        __sync_fetch_and_add(&t->write_count, 1);
        return 0;
    }

    /* 없으면 새로 만든다. 동시에 같은 키가 들어와도 BPF_ANY 라 덮어쓸 뿐 오류가 아니다 */
    struct write_tag nt = {
        .cgroup_id = cg,
        .ts_ns = bpf_ktime_get_ns(),
        .write_count = 1,
    };
    bpf_map_update_elem(&write_tags, &id, &nt, BPF_ANY);
    return 0;
}

#endif /* WRITE_TAG_H */
