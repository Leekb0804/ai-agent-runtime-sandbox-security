# v0.1 2주차 설계 메모 (w2d2 갱신본)

상태: **초안.** 표기: [VM확인] 사용자 VM 출력으로 확인된 것 / [계획서] 계획서와 2주차 상세 계획 / [추론] Claude(채팅)의 판단 / [확인필요] 실험으로 검증할 것. Claude(채팅)는 소스 전체를 보지 못했고, 본 파일은 `watcher.bpf.c`, `event.h`, `dispatcher.c`, `detector.h`, `jsonl.c`, `loader.c`, `build.sh`와 grep 일부만 확인했다.

## 1. 결정 요약

| # | 항목 | 결정 | 상태 |
|---|---|---|---|
| 8 | `/tmp/trigger` 관측 누락 | 재현 불가로 기록. 38회 관측, 누락 0. 원인 미규명. `; true`는 유지 | [VM확인] 커밋 570acb0 |
| 1 | 위협 모델 | 3열 표(막는 것 / 기록만 / 범위 밖·한계). "차단"은 후속 행동 중단(사후 종료). 경로 비교는 SUSPECT, TLS는 한계로 유지, 쓰기 변형 범위는 open 시점만 | 확정본 `docs/threat-model-w2.md`. 한계 4개는 5c9c212 |
| 2 | 후킹 지점 | 쓰기 태깅: `security_file_open` fentry(쓰기 모드). exec 조회: **`security_bprm_check` fentry**. `sched_process_exec`는 스크립트에서 인터프리터 inode를 봐서 제외 | C 프로브로 동작 확인 [VM확인] (9a30829, 1ed42e0). 모든 exec 경로가 이 훅을 지나는지는 [확인필요] |
| 3 | 태깅 키 | `(s_dev, i_ino)`. 쓰기 open이 overlay 층과 실제 파일시스템 층에서 두 번 걸리므로 두 쌍을 모두 저장. 값은 `{cgroup_id, ts_ns, write_count}` | 두 쌍 저장, 컨테이너 안 exec는 `(40, ino)`, 호스트 exec는 `(265289730, ino)`로 조회됨 [VM확인]. 한 파일 기준 |
| 4 | 맵 | LRU_HASH 10240, 파일당 항목 2개라 실효 약 5000파일. 10분 만료는 **커널이 아니라 `write_exec_boundary` 탐지기가 `ts_ns - tag_ts_ns`로 판단**하는 안(목요일 결정). 밀려난 횟수 측정은 3주차 | [추론], 경과 시간 계산 가능은 [VM확인] |
| 5 | exec 필터 | 기존 `on_execve`(세션 cgroup만 통과)는 그대로 두고, 세션 필터가 없는 `on_bprm_check`를 추가. 맵 미스면 바로 반환, 히트 때만 emit | 구현 [VM확인] (1ed42e0) |
| 6 | 더미 탐지기 | 당분간 유지. 둘 다 `KIND_BIT(EVT_EXEC)`만 구독해 `TAG_HIT`을 받지 않음. 실제 탐지기가 서면 테스트 전용으로 분리 | [VM확인] (`grep`) |
| 7 | `host.sh` | 단계 분리 권고. `s01` 만들기 전에 정한다. 러너 프로세스가 세션 cgroup 밖인지 확인 필요 | 미정 |
| 9 | 경로 비교를 미룰 기준 | `write_exec_boundary` 결과를 본 뒤 정한다 | 미정 |
| - | 미스 경로 성능 | 호스트 전체 exec에 걸리는 훅이며 첫 줄에서 맵 조회만 한다. 측정은 3주차 부하 시험에서 (제안) | 미측정 |

## 2. 환경 사실 [VM확인]

- 커널 7.0.0-27, aarch64. `security_file_open`, `security_bprm_check`는 BTF에서 `static` 함수로 표시되지만 fentry 부착이 된다. BTF가 있다.
- 에이전트는 사용자 네임스페이스 안 root: `uid=0`, `CapEff=000001ffffffffff`. `uid_map`은 `0 -> 호스트 1000`. 에이전트가 쓴 파일의 호스트 쪽 소유자는 uid 1000. 컨테이너 안 `/tmp`는 root 소유 `drwxrwxr-x`. `/workspace`는 없다. 하드닝(비root, cap 축소, `no_new_privs`)은 v0.1에서 적용하지 않는다.
- 기존 구조: 이벤트는 `event.h`의 공통 헤더와 ring buffer. 로더 `handle_event`가 헤더 `cgroup_id`로 세션을 찾고 `events.jsonl`에 쓴 뒤 디스패처에 넘긴다. 탐지기는 kind 비트마스크로 구독하며 kind는 32 미만이다. `dispatcher.c`의 `min_len_for_kind`는 모르는 kind에 헤더 크기를 돌려주므로 새 kind는 case를 추가해야 길이가 검증된다.
- 런처(`mycontainer_run`)도 세션 cgroup 안에 있다. 세션 시작 과정의 쓰기(`/proc/<pid>/{setgroups,uid_map,gid_map}`, `state`, overlay workdir의 `#<inode>` 파일)가 세션당 약 7개 태그된다.

## 3. 설계

### 3.1 쓰기 태깅 (`src/bpf/write_tag.h`)
`security_file_open`에서 현재 task의 cgroup이 세션 cgroup이고 `f_mode & 0x2`이면 `(s_dev, i_ino)`를 키로 맵을 갱신한다. 경로나 `comm`으로 거르지 않는다(`comm`은 에이전트가 바꿀 수 있어 회피 경로가 된다). 태그 소유자는 **마지막으로 쓴 세션**이다(쓰기 open마다 덮어씀). 쓴 프로세스의 pid는 저장하지 않는다.

### 3.2 exec 조회와 이벤트 (`src/bpf/tag_hit.h`)
`security_bprm_check`에서 `bprm->file`의 `(s_dev, i_ino)`로 `write_tags`를 조회하고, 히트하면 `EVT_TAG_HIT`(= 5)을 올린다. 스크립트는 이 훅이 두 번 불린다(첫 호출이 스크립트, 둘째가 인터프리터). 인터프리터는 태그가 없어 히트가 나지 않는다.

| 위치 | 필드 | 값 |
|---|---|---|
| 헤더 | `cgroup_id` | **태그 소유(쓴) 세션의 cgroup**. 로더가 세션 폴더를 고르는 기준 |
| 헤더 | `pid` | exec한 프로세스의 tgid |
| 헤더 | `ts_ns` | 이벤트 시각 |
| payload | `exec_cgroup_id` | exec한 프로세스의 cgroup. 탐지기가 헤더 `cgroup_id`와 비교해 세션 밖 실행을 판정 |
| payload | `tag_ts_ns`, `tag_write_count`, `dev`, `ino`, `filename` | 맵 값과 `bprm->filename` |

이 이벤트만 헤더 `pid`(실행자)와 `cgroup_id`(소유자)가 다른 주체를 가리키며, `event.h`에 예외를 명시했다. `tag_write_count`는 지금 쓰는 곳이 없지만 남겨 둔다(3주차 오탐 튜닝 때 쓸모가 없으면 이벤트에서 뺀다).

### 3.3 판정 (유저스페이스, 목요일 구현)
| 상황 | 판정 |
|---|---|
| 실행자 cgroup ≠ 태그 소유 cgroup | BLOCK |
| 같은 cgroup (빌드 후 실행) | SUSPECT 또는 무시. 오탐 측정 뒤 조정 |

판정은 exec 이후에 나오는 사후 차단이다. `kill_session`은 세션 cgroup 안의 프로세스만 끊으므로 세션 밖에서 일어난 실행 자체는 멈추지 못한다. 경과 시간은 `ts_ns - tag_ts_ns`(같은 단조 시계)로 계산하고 reason에 넣는다.

### 3.4 탐지기 작성 규칙 (기존 한계 항목의 반영처)
- 태깅과 구분의 키는 pid가 아니라 `(s_dev, i_ino)`다. exec는 pid를 유지하므로 같은 pid에서 다른 프로그램의 이벤트가 이어진다.
- 탐지기는 서로 독립이며 실행 순서에 의존하지 않는다. 등록은 constructor이고 파일 간 호출 순서는 보장되지 않는다.
- `on_event`의 `h`는 ring buffer 메모리를 직접 가리키므로 함수가 끝나면 덮인다. 필요한 값은 함수 안에서 복사한다.

## 4. 실험 결과 (w2d1~w2d2) [VM확인]

### 4.1 bpftrace 관측 (호스트 커널, 프로젝트 로더와 무관)

| 실험 | 관측 |
|---|---|
| 스크립트(`#!/bin/sh`) 쓰기 후 컨테이너 안에서 실행 | 쓰기 open이 `(40, ino)`, `(265289730, ino)` 두 쌍으로 두 번 찍힘. `security_bprm_check`는 첫 호출에서 `trigger`, 둘째 호출에서 `busybox` |
| 같은 실행의 `sched_process_exec` | `exe_file` inode가 busybox(`2097917`, `stat -L`로 `bin/sh`와 같음). 쓰기 때 값과 다름 |
| 바이너리(busybox 복사본) 쓰기 후 실행 | `security_bprm_check`, `sched_process_exec` 모두 쓰기 때와 같은 ino |
| 호스트에서 upperdir의 같은 파일 실행 (`sudo`) | `dev=265289730 ino=3549432`, 실행자 cgroup `304085`(컨테이너와 다름), 소유자 uid 1000 |

### 4.2 C 프로브 확인
- 쓰기 태깅(9a30829): 세션 안에서 쓰면 두 쌍이 들어가고 `cgroup_id`는 세션 cgroup과 같다. 호스트에서 쓴 파일은 맵에 없다. 맵에는 세션 시작 과정의 쓰기(위 2절)도 들어간다.
- 히트 이벤트(1ed42e0): 컨테이너 안 실행은 `TAG_HIT` 1줄(`exec_cgroup_id == cgroup_id`, `dev=40`), 호스트 실행은 1줄(`exec_cgroup_id=304085`, `cgroup_id=343470`, `dev=265289730`, `filename`은 upperdir 경로)이고 둘 다 쓴 세션의 `events.jsonl`에 귀속됐다(`_unattributed` 없음, 세션이 끝나고 약 31초 뒤의 호스트 실행도 마찬가지).
- 호스트 실행 `ts_ns - tag_ts_ns`는 약 31.4초이고 `logged_at_ms` 차이와 일치한다.
- `sudo ./run_scenarios.sh`: 2/2 통과, `lost=0`. s99는 `TAG_HIT` 한 줄이 늘어 이벤트가 4줄이 됐다.
- 한계: 파일 하나, 실행 두 번 기준. 호스트 실행은 root(`sudo`)였고 세션이 끝난 뒤의 파일이었다. 비root 호스트 실행, 여러 파일, 부하 상황은 보지 않았다. 새 kind용 단위 테스트는 아직 없다.

## 5. 미탐 범위 (수용한 한계와 연결)
open 시점의 쓰기 모드만 태깅하므로 rename, hardlink, mmap 쓰기, 복사 후 실행은 탐지하지 못한다. `dev=40` 같은 overlay 장치 번호가 컨테이너 사이에서 재사용되면 키가 겹칠 수 있다 [확인필요]. 평가는 제한된 재현 시나리오에 기반하며 일반화는 검증되지 않았다.

## 6. 확인할 것 (순서)
1. 새 kind 단위 테스트: `TAG_HIT`보다 짧은 이벤트 무시, 구독자에게만 분배(`test_dispatcher.c`).
2. 목요일: `write_exec_boundary` 탐지기와 합성 `TAG_HIT` 단위 테스트, 더미와 동시 동작. 10분 만료를 탐지기에서 처리할지 결정.
3. 금요일 앞: 결정 7번(`host.sh`)과 `/workspace`(없으면 upperdir 경로로 대체).
4. 금요일: `s01`, `s02` 시나리오와 회귀 등록.
5. 결정 9번(경로 비교를 미룰 기준).
6. 3주차: 미스 경로 성능과 맵 밀려남 측정, `dev=40` 재사용 확인.
