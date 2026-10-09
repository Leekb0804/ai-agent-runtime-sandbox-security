# v0.1 2주차 설계 메모 (초안)

상태: **초안.** 표기: [VM확인] 사용자 VM 출력으로 확인된 것 / [계획서] 계획서와 2주차 상세 계획 / [추론] Claude(채팅)의 판단 / [확인필요] 부착이나 실험으로 검증할 것. Claude(채팅)는 소스 전체를 보지 못했고, `watcher.bpf.c`, `event.h`와 grep 일부만 확인했다.

## 1. 결정 요약

| # | 항목 | 결정 | 상태 |
|---|---|---|---|
| 8 | `/tmp/trigger` 관측 누락 | 재현 불가로 기록. 38회 관측, 누락 0. 원인 미규명. `; true`는 유지 | [VM확인] 커밋 570acb0 |
| 1 | 위협 모델 | 3열 표(막는 것 / 기록만 / 범위 밖·한계). "차단"은 후속 행동 중단(사후 종료) | 한계 4개는 수용한 한계로 기록(5c9c212). 본문은 프로젝트 파일의 threat-model-w2.md 초안(저장소에는 아직 없음, 확정 후 docs/ 에 추가) |
| 2 | 후킹 지점 | 쓰기 태깅: `security_file_open`에서 쓰기 모드일 때. exec 조회: **`security_bprm_check`** (스크립트와 바이너리 모두 대상 파일을 봄). `sched_process_exec`는 스크립트에서 인터프리터 inode를 봐서 제외 | 아래 4절 [VM확인], 모든 exec 경로가 이 훅을 지나는지는 [확인필요] |
| 3 | 태깅 키 | `(s_dev, i_ino)`. 쓰기 open이 overlay 층과 실제 파일시스템 층에서 두 번 걸리므로 **매 쓰기 open마다 저장해 두 쌍을 모두** 둔다. 값은 `{cgroup_id, ts_ns, write_count}` | C 프로브(`src/bpf/write_tag.h`)로 두 쌍이 저장됨 [VM확인], 한 파일 기준. 표본 확대는 [확인필요] |
| 4 | 맵 | LRU_HASH 10240, 10분 만료(상수 분리). 파일당 항목이 2개이므로 실효 용량은 약 5000파일. 밀려난 횟수를 셀 방법을 정하고 측정 후 조정 | [계획서], 용량 계산은 [추론] |
| 5 | exec 필터 | 현재 `on_execve`는 세션 cgroup만 통과(`watcher.bpf.c` 55~58행). 쓰기 probe는 세션 cgroup만, 새 exec 조회 probe는 모든 cgroup을 보고 맵 히트 때만 emit. **기존 `on_execve`는 건드리지 않고 프로브를 추가** | 필터 현황 [VM확인] |
| 6 | 더미 탐지기 | 당분간 유지. 실제 탐지기가 서면 테스트 전용으로 분리 | 권고 |
| 7 | `host.sh` | 단계 분리(안쪽 단계 완료를 러너가 확인한 뒤 호스트 단계 실행) | 러너 프로세스가 세션 cgroup 밖인지 [확인필요] |
| 9 | 경로 비교를 미룰 기준 | 아직 정하지 않음 (아래 6절) | 미정 |

## 2. 환경 사실 [VM확인]

- 커널 7.0.0-27, aarch64. `security_file_open`, `security_bprm_check`는 kallsyms에 있고 BTF에서 `static` 함수로 표시된다. `sched_process_exec` tracepoint, BTF(`/sys/kernel/btf/vmlinux`)가 있다. 두 `fentry` 프로브 부착은 bpftrace에서 성공했다.
- 에이전트는 사용자 네임스페이스 안 root: `uid=0`, `CapEff=000001ffffffffff`. `uid_map`은 `0 -> 호스트 1000` 한 줄. 에이전트가 쓴 파일의 호스트 쪽 소유자는 uid 1000이다 (`ls -ln`으로 확인). 컨테이너 안 `/tmp`는 root 소유 `drwxrwxr-x`. `/workspace`는 없다.
- 하드닝(비root, cap 축소, `no_new_privs`)은 v0.1에서 적용하지 않는다. 탐지기가 cgroup과 inode로 판정하므로 uid에 영향받지 않을 것으로 보지만 [추론], 비root로 돌려 확인한 적은 없다.
- 기존 구조: 이벤트는 `event.h`의 공통 헤더(`event_hdr`)와 ring buffer. 새 kind는 enum 끝에 추가하고(`EVT_WRITE`, `EVT_OPEN`은 예약됨), `dispatcher.c`의 `min_len_for_kind`에 case를 더해야 한다. 탐지기는 kind 비트마스크로 구독하며 kind는 32 미만이어야 한다. 현재 `EVT_EXEC`의 filename은 `execve`의 첫 인자(요청 이름)이고, 최종 경로는 없다.

## 3. 설계

### 3.1 쓰기 태깅
`security_file_open`에서 현재 task의 cgroup이 세션 cgroup이고 파일이 쓰기 모드로 열리면 `(s_dev, i_ino)`를 키로 맵을 갱신한다. write마다가 아니라 open 시점이라 부하가 작다 [계획서]. overlay 위에서는 같은 open이 두 쌍으로 두 번 걸리며(4절), 둘 다 저장한다. 컨테이너 밖 쓰기는 맵에 들어가지 않는다.

### 3.2 exec 조회와 이벤트
`security_bprm_check`에서 `bprm->file`의 `(s_dev, i_ino)`로 맵을 조회하고, 히트하면 태그 소유 cgroup, 태그 시각, 실행자 cgroup, 실행자 pid, 경로를 담은 이벤트를 같은 ring buffer와 공통 헤더로 올린다. 이름은 코드에 맞춘다(계획서는 `EVT_TAG_HIT`). 스크립트는 이 훅이 두 번 불려 첫 호출이 스크립트, 둘째가 인터프리터다. 둘 다 조회해도 인터프리터가 태그된 경우만 히트하므로 해롭지 않다고 보지만 [추론], 중복 이벤트 처리는 [확인필요]. 미스 경로는 가볍게 끝나야 한다 [확인필요: 성능].

### 3.3 판정 (유저스페이스)
| 상황 | 판정 |
|---|---|
| 실행자 cgroup ≠ 태그 소유 cgroup | BLOCK |
| 같은 cgroup (빌드 후 실행) | SUSPECT 또는 무시. 오탐 측정 뒤 조정 |

판정은 exec 이후에 나오는 사후 차단이다. `kill_session`은 세션 cgroup 안의 프로세스만 끊으므로 세션 밖에서 일어난 실행 자체는 멈추지 못한다.

### 3.4 탐지기 작성 규칙 (기존 한계 항목의 반영처)
- 태깅과 구분의 키는 pid가 아니라 `(s_dev, i_ino)`다. exec는 pid를 유지하므로 같은 pid에서 다른 프로그램의 이벤트가 이어진다.
- 탐지기는 서로 독립이며 실행 순서에 의존하지 않는다. 등록은 constructor이고 파일 간 호출 순서는 보장되지 않는다.

## 4. 실험 결과 (w2d1, bpftrace, 호스트 커널 관측) [VM확인]

| 실험 | 관측 |
|---|---|
| 스크립트(`#!/bin/sh`) 쓰기 후 컨테이너 안에서 실행 | 쓰기 open이 `(40, ino)`, `(265289730, ino)` 두 쌍으로 두 번 찍힘. exec 직전 읽기 open도 같은 두 쌍. `security_bprm_check`는 첫 호출에서 `trigger`(`dev=40`, 같은 ino), 둘째 호출에서 `busybox` |
| 같은 실행의 `sched_process_exec` | `exe_file` inode가 busybox(`2097917`, `stat -L`로 `bin/sh`와 같음). 쓰기 때 값과 다름. 이 방식으로는 스크립트 exec가 태그와 매칭되지 않는다 |
| 바이너리(busybox 복사본) 쓰기 후 실행 | `security_bprm_check`, `sched_process_exec` 모두 쓰기 때와 같은 ino |
| 호스트에서 upperdir의 같은 파일 실행 (`sudo`) | `security_bprm_check`: `dev=265289730 ino=3549432`(컨테이너의 두 번째 쌍과 같음), 실행자 cgroup `304085`(컨테이너와 다름), 소유자 uid 1000, `-rwxr-xr-x` |

- 해석 [추론]: `dev=265289730`은 major 253, minor 2(호스트 `stat`의 `fd02`)다. `dev=40`은 overlay 마운트의 장치로 보이며 컨테이너가 바뀌어도 40이 반복됐다. 번호가 재사용되면 다른 컨테이너와 키가 겹칠 수 있다 [확인필요].
- 한계: 파일 하나, 실행 한 번 기준이다. 호스트 실행은 root(sudo)였고 세션이 끝난 뒤의 파일이었다. 실행 중인 세션의 파일을 호스트가 실행하는 경우, 호스트 비root 실행은 보지 못했다.

### 4.1 C 프로브 확인: 쓰기 태깅 (`src/bpf/write_tag.h`) [VM확인]

- 부착과 동작: `fentry/security_file_open` 프로그램이 로더에 의해 부착되고 `write_tags` 맵(LRU_HASH 10240, pin 안 함)에 항목이 생겼다.
- 세션 안에서 `/tmp/trigger`를 쓰자 `(dev=40, ino=3549462)`와 `(dev=265289730, ino=3549462)` 두 항목이 들어갔고, 값의 `cgroup_id`는 `agent-run`이 출력한 세션 cgroup과 같았다(`write_count=1`).
- 호스트(세션 밖)에서 쓴 파일의 inode는 맵에 없었다 (파일 하나 기준).
- `sudo ./run_scenarios.sh`: s00, s99 2/2 통과, `lost=0`, `_unattributed` 비어 있음. 새 프로그램이 기존 시나리오를 깨지 않았다.
- 맵에는 `/tmp/trigger` 외 항목도 들어간다. 임시 프로브(`security_file_open`에서 파일 이름, 부모 이름, `comm`을 출력)로 세션 하나의 쓰기 open 7건을 확인했다: `mycontainer_run`(런처)이 `/proc/<자식 pid>/setgroups`, `uid_map`, `gid_map`을 씀(`dev=26`, `mountinfo`의 `0:26`은 `/proc`), 런처가 `containers/mycontainer-N/state`를 씀(`dev=265289730`), 자식(`comm=exe`)이 overlay workdir 안의 `#<inode>` 이름 파일을 염(용도는 확인하지 못함), `sh`가 `trigger`를 `dev=40`, `dev=265289730` 두 쌍으로 염. 즉 태그는 "에이전트가 쓴 파일"이 아니라 "세션 cgroup 안의 프로세스가 쓰기 모드로 연 파일"이고, 런처도 세션 cgroup 안에 있다. 항목은 세션당 약 7개로 용량을 조금 쓸 뿐이라 지금은 거르지 않는다. `comm`으로 거르면 에이전트가 프로세스 이름을 바꿔 회피할 수 있다.
- 아직 안 한 것: `security_bprm_check` 조회와 히트 이벤트. 헤더 `cgroup_id`는 태그 소유 세션의 cgroup으로 하고 실행자 cgroup은 payload에 두기로 정했다(사용자 확인, w2d1).

## 5. 미탐 범위 (수용한 한계와 연결)
open 시점의 쓰기 모드만 태깅하므로 rename, hardlink, mmap 쓰기, 복사 후 실행은 탐지하지 못한다. 평가는 제한된 재현 시나리오에 기반하며 일반화는 검증되지 않았다.

## 6. 확인할 것 (순서)
1. 쓰기 태깅은 C 프로브로 확인됨(4.1절). 다음은 `security_bprm_check` 조회와 히트 이벤트 추가: 새 kind를 `event.h`와 `dispatcher.c`의 `min_len_for_kind`에 추가한다(헤더 `cgroup_id`는 태그 소유 세션 cgroup으로 정함, 4.1절). `jsonl.c`와 `session_log.c`가 새 kind를 어떻게 다루는지도 확인한다.
2. `dev=40` 재사용 위험: 컨테이너를 여러 번 띄워 dev 값을 비교.
3. 실행 중인 세션의 파일을 호스트 비root가 실행하는 경우, `/workspace` bind mount를 만들지 정한다.
4. 러너 프로세스의 cgroup 위치(`host.sh` 지원 전제).
5. 위 결과로 9번(경로 비교를 미룰 기준) 결정.
