/*
 * event.h
 *
 * 커널(watcher.bpf.c)과 유저스페이스(loader.c)가 "함께 include"하는 공용 헤더.
 * ring buffer로 넘어가는 이벤트의 바이트 배치를 양쪽이 똑같이 해석하도록
 * 구조체를 한 곳에서만 정의한다. (이 파일은 실행되는 코드가 아니라 형식 정의)
 *
 * 타입(__u32, __u64)의 출처:
 *   - watcher.bpf.c : vmlinux.h 가 제공 (이 헤더보다 먼저 include 해야 함)
 *   - loader.c      : <linux/types.h> 가 제공 (이 헤더보다 먼저 include 해야 함)
 *
 * 하위 호환 규칙: 기존 필드의 순서/크기를 바꾸지 않고, 새 필드는 뒤에만 추가한다.
 */
#ifndef EVENT_H
#define EVENT_H

/* 이벤트 종류. 헤더의 kind 값으로 payload가 어떤 구조체인지 구분한다. */
enum evt_kind {
    EVT_EXEC  = 1,   /* execve 호출 (v0.1 1주차 구현) */
    EVT_WRITE = 2,   /* 파일 쓰기 (2주차 예정) */
    EVT_OPEN  = 3,   /* 파일 open (2주차 예정) */
    EVT_DNS   = 4,   /* DNS 쿼리 (v0.3 예정) */
    EVT_TAG_HIT = 5,   /* 세션이 쓴 파일이 exec 됨 (2주차) */
};

/*
 * 모든 이벤트가 맨 앞에 갖는 공통 헤더.
 * 종류와 무관하게 "누가(pid, cgroup), 언제(ts)"는 항상 같은 위치에 있으므로
 * 로더는 먼저 헤더만 읽고 kind를 보고 나머지를 해석할 수 있다.
 */
struct event_hdr {
    __u32 kind;          /* enum evt_kind */
    __u32 pid;           /* 이벤트를 일으킨 프로세스의 tgid (사용자 눈에 보이는 PID) */
    __u64 cgroup_id;     /* 이벤트가 발생한 cgroup id (세션 식별 기준). EVT_TAG_HIT 만 예외: 파일을 쓴 세션의 cgroup (struct evt_tag_hit 주석 참고) */
    __u64 ts_ns;         /* bpf_ktime_get_ns() 값. 부팅 후 경과 나노초 (벽시계 아님) */
    __u32 payload_len;   /* 헤더 뒤 payload 길이(바이트) */
    __u32 _pad;          /* 8바이트 정렬용 패딩. 구조체 크기를 양쪽에서 동일하게 유지 */
};

#define MAX_FILENAME 256

/*
 * EVT_EXEC 이벤트: 헤더 + payload(실행 요청된 파일 이름).
 * 첫 필드가 헤더이므로 (struct event_hdr *) 로 캐스팅해 헤더만 읽을 수 있다.
 * 4주차에 resolved_path 등을 추가할 때는 filename 뒤에 덧붙인다.
 */
struct evt_exec {
    struct event_hdr hdr;
    char filename[MAX_FILENAME];   /* execve의 첫 번째 인자. 길면 잘림 */
};

/*
 * EVT_TAG_HIT 이벤트: write_tags 에 태그된 파일이 exec 되었다.
 * 예외 규칙: 이 이벤트만 헤더의 cgroup_id 와 pid 가 서로 다른 주체를 가리킨다.
 *   hdr.cgroup_id   : 파일을 쓴(태그한) 세션의 cgroup. 로더가 이 값으로 세션 폴더를 고른다.
 *   hdr.pid         : exec 한 프로세스의 tgid
 *   exec_cgroup_id  : exec 한 프로세스의 cgroup. 탐지기가 hdr.cgroup_id 와 비교해 세션 밖 실행을 판정한다.
 * 같은 세션 안에서 쓰고 실행한 경우에도 이 이벤트가 나온다 (두 cgroup 이 같다).
 */
struct evt_tag_hit {
    struct event_hdr hdr;
    __u64 exec_cgroup_id;          /* exec 한 프로세스의 cgroup */
    __u64 tag_ts_ns;               /* 태그 시각 (마지막 쓰기 open, 부팅 후 경과 ns) */
    __u64 tag_write_count;         /* 태그된 쓰기 open 횟수 */
    __u32 dev;                     /* 파일 신원: s_dev */
    __u32 _pad;                    /* 8바이트 정렬용 */
    __u64 ino;                     /* 파일 신원: i_ino */
    char filename[MAX_FILENAME];   /* bprm->filename (exec 요청 경로). 길면 잘림 */
};

/*
 * ring buffer 예약 실패(가득 참)로 버려진 이벤트를 세는 칸의 번호.
 * 커널 쪽 drop_counts 맵의 key 이자 로더가 출력할 때 쓰는 번호이다.
 */
enum drop_kind {
    DROP_EXEC    = 0,   /* EVT_EXEC 이벤트 */
    DROP_TAG_HIT = 1,   /* EVT_TAG_HIT 이벤트 */
    DROP_KIND_MAX       /* 개수 (맵의 max_entries 와 같다) */
};

#endif /* EVENT_H */
