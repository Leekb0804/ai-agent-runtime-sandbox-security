# v0.1 2주차 설계 메모 (w2d3 최종본)

상태: **w2 최종본.** [확인필요] 항목은 3주차에 확인한다. 표기: [VM확인] 사용자 VM 출력으로 확인된 것 / [계획서] 계획서와 2주차 상세 계획 / [추론] Claude(채팅)의 판단 / [확인필요] 실험으로 검증할 것. Claude(채팅)는 소스 전체를 보지 못했고, 본 파일은 `watcher.bpf.c`, `event.h`, `dispatcher.c`, `detector.h`, `jsonl.c`, `loader.c`, `build.sh`, `dummy_block.c`, `verdict_handler.c`, `test_dispatcher.c`, `run_scenarios.sh`(일부), `tools/judge.sh`(일부), `tools/test_runner.sh`, `tools/mock/run_container.sh`와 grep 일부만 확인했다.

## 1. 결정 요약

| # | 항목 | 결정 | 상태 |
|---|---|---|---|
| 8 | `/tmp/trigger` 관측 누락 | 재현 불가로 기록. 38회 관측, 누락 0. 원인 미규명. `; true`는 유지 | [VM확인] 커밋 570acb0 |
| 1 | 위협 모델 | 3열 표(막는 것 / 기록만 / 범위 밖·한계). "차단"은 후속 행동 중단(사후 종료). 경로 비교는 SUSPECT, TLS는 한계로 유지, 쓰기 변형 범위는 open 시점만 | 확정본 `docs/threat-model-w2.md`. 수용한 한계는 5c9c212, 260126a, fc540fa |
| 2 | 후킹 지점 | 쓰기 태깅: `security_file_open` fentry(쓰기 모드). exec 조회: **`security_bprm_check` fentry**. `sched_process_exec`는 스크립트에서 인터프리터 inode를 봐서 제외 | C 프로브와 탐지기로 동작 확인 [VM확인] (9a30829, 1ed42e0, 4efc399). 모든 exec 경로가 이 훅을 지나는지는 [확인필요] |
| 3 | 태깅 키 | `(s_dev, i_ino)`. 쓰기 open이 overlay 층과 실제 파일시스템 층에서 두 번 걸리므로 두 쌍을 모두 저장. 값은 `{cgroup_id, ts_ns, write_count}` | 두 쌍 저장, 컨테이너 안 exec는 `(40, ino)`, 호스트 exec는 `(265289730, ino)`로 조회됨 [VM확인]. 한 파일 기준 |
| 4 | 맵과 만료 | LRU_HASH 10240, 파일당 항목 2개라 실효 약 5000파일. 10분 만료는 **커널이 아니라 `write_exec_boundary` 탐지기가 `ts_ns - tag_ts_ns`로 판단**하고, 만료되면 세션 밖 실행도 SUSPECT로 내린다 (사용자 결정). 밀려난 횟수 측정은 3주차 | 탐지기 구현 [VM확인] (4efc399). 맵 밀려남은 [확인필요] |
| 5 | exec 필터 | 기존 `on_execve`(세션 cgroup만 통과)는 그대로 두고, 세션 필터가 없는 `on_bprm_check`를 추가. 맵 미스면 바로 반환, 히트 때만 emit | 구현 [VM확인] (1ed42e0) |
| 6 | 더미 탐지기 | 유지. 둘 다 `KIND_BIT(EVT_EXEC)`만 구독해 `TAG_HIT`을 받지 않음. 단 `s99`가 `dummy_block`의 BLOCK에 의존하므로 테스트 전용으로 분리하지 않았다 | [VM확인]. 분리는 3주차에 검토 |
| 7 | `host.sh` 지원 | **A안**: `agent-run`이 끝난 뒤 러너가 컨테이너의 upperdir(`MYC_UPPER`)를 주고 호스트에서 `host.sh`를 실행한다 (3.5절). B안(컨테이너가 살아 있는 동안 실행하고 안팎을 동기화)은 3주차 실제 kill 검증에 필요 | 구현 [VM확인] (64f64e7). 러너가 세션 cgroup 밖이라는 가정은 `s01`의 BLOCK으로 확인됨 |
| 9 | 경로 비교를 미룰 기준 | 경로 비교 탐지기(resolved 경로 vs 요청 이름)는 유지하되 3단계 조건으로 시작 여부를 거른다 (7절) | 정함 (w2d3, 사용자 확정) |
| - | 미스 경로 성능 | 호스트 전체 exec에 걸리는 훅이며 첫 줄에서 맵 조회만 한다. 측정은 3주차 부하 시험에서 (제안) | 미측정 |
| - | BLOCK 의 대응 대상 | 열린 설계 질문 (8절). 쓴 세션 종료, 실행한 프로세스 종료, 실행 자체 거부, 동결, kill 을 설정으로 | 미정, 3주차 오탐 측정 뒤 결정 |

## 2. 환경 사실 [VM확인]

- 커널 7.0.0-27, aarch64. `security_file_open`, `security_bprm_check`는 BTF에서 `static` 함수로 표시되지만 fentry 부착이 된다. BTF가 있다. 활성 LSM에는 `bpf`가 없다 (8절).
- 에이전트는 사용자 네임스페이스 안 root: `uid=0`, `CapEff=000001ffffffffff`. `uid_map`은 `0 -> 호스트 1000`. 에이전트가 쓴 파일의 호스트 쪽 소유자는 uid 1000. 컨테이너 안 `/tmp`는 root 소유 `drwxrwxr-x`. `/workspace`는 없다. 하드닝(비root, cap 축소, `no_new_privs`)은 v0.1에서 적용하지 않는다.
- 컨테이너 안 `/tmp/x`는 호스트에서 `/var/lib/mycontainer/containers/mycontainer-<N>/upper/tmp/x`이고, 컨테이너가 끝나도 남는다. `<N>`은 세션 ID의 끝 숫자와 같았다(여러 세션에서 관찰, 코드로는 확인하지 않음. 수용한 한계 fc540fa).
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

### 3.3 판정 (`src/loader/detectors/write_exec_boundary.c`, 4efc399)
`TAG_HIT`만 구독하고 판정은 두 번의 비교로 정해진다.

| 실행자 | 쓴 지 | 판정 |
|---|---|---|
| 쓴 세션 밖 (`exec_cgroup_id` ≠ 헤더 `cgroup_id`) | 10분 이내 | **BLOCK** |
| 쓴 세션 밖 | 10분 초과 (만료) | SUSPECT |
| 쓴 세션 안 (빌드 후 실행 등) | 무관 | SUSPECT. 오탐은 3주차에 측정 |

경과 시간은 `ts_ns - tag_ts_ns`(같은 단조 시계)이고, 정확히 10분까지는 유효, 1ns라도 넘으면 만료다. reason에는 경과 시간과 경로를 넣고 128바이트에서 자른다(`세션 밖 실행, 쓴 지 25.945초: <경로>`). 시계 이상으로 태그 시각이 이벤트 시각보다 뒤이면 경과를 0으로 본다.

판정은 exec 이후에 나오는 사후 판정이다. BLOCK이면 `verdict_handler`가 헤더 `cgroup_id`(쓴 세션)로 세션을 찾아 기록하고 세션당 한 번 `kill_session`을 요청한다. 지금은 스텁이라 `would_kill`만 기록한다. `kill_session`은 세션 cgroup 안의 프로세스만 끊으므로 세션 밖에서 일어난 실행 자체는 멈추지 못한다. 탐지기는 실행한 쪽이 누구인지 구분하지 못하고 cgroup이 다르다는 것만 본다.

### 3.4 탐지기 작성 규칙 (기존 한계 항목의 반영처)
- 태깅과 구분의 키는 pid가 아니라 `(s_dev, i_ino)`다. exec는 pid를 유지하므로 같은 pid에서 다른 프로그램의 이벤트가 이어진다.
- 탐지기는 서로 독립이며 실행 순서에 의존하지 않는다. 등록은 constructor이고 파일 간 호출 순서는 보장되지 않는다.
- `on_event`의 `h`는 ring buffer 메모리를 직접 가리키므로 함수가 끝나면 덮인다. 필요한 값은 함수 안에서 복사한다.

### 3.5 러너의 호스트 스텝 (`run_scenarios.sh`, 64f64e7)
시나리오 폴더에 `host.sh`가 있으면 러너가 `agent-run`이 끝난 뒤 호스트에서 실행한다 (결정 7번 A안).

- `agent-run`이 foreground로 끝난 뒤에 실행하므로 컨테이너가 쓴 파일이 이미 `upperdir`에 있어 레이스가 없다. 러너는 컨테이너 폴더를 `$CONTAINERS_ROOT/mycontainer-<세션 ID 끝 숫자>`로 찾고, 폴더가 없으면 시작하지 않고 FAIL한다(fail-closed).
- `host.sh`는 환경변수 `MYC_UPPER`(그 컨테이너의 upperdir)를 받고, 에이전트가 쓴 파일을 **직접** 실행한다. `sh <파일>`로 넘기면 탐지되지 않는다 (5절).
- 호스트 스텝 뒤에는 `events.jsonl`의 줄 수가 스텝 전보다 늘 때까지 먼저 기다린 뒤 `wait_settled`를 부른다. `wait_settled`는 "안 변함"만 보는데 호스트 스텝 직전의 로그는 이미 안정되어 있어서, 새 줄이 오기 전에 안정으로 끝날 수 있기 때문이다.
- 시나리오 폴더는 `MYC_SCEN_DIR`로 바꿀 수 있고, 러너 테스트는 `s00`, `s99` 링크만 든 임시 폴더를 쓴다. 시나리오가 늘어도 가짜 환경의 러너 테스트가 흔들리지 않게 하려는 것이다 (4.3절).

## 4. 실험 결과 (w2d1~w2d3) [VM확인]

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
- 새 kind 단위 테스트(3e0b598): `TAG_HIT` 분배와 길이 검증 7개. `min_len_for_kind`의 case를 지우면 3개 FAIL(직접 2개, 연쇄 1개).

### 4.3 탐지기와 시나리오 (w2d3)
- 실제 로더: 컨테이너가 `/tmp/payload`를 쓰고 끝난 뒤 호스트가 직접 실행하면 `write_exec_boundary`의 BLOCK과 `would_kill`이 쓴 세션 로그에 남는다 (`쓴 지 25.945초`). 이 실행에서 쓴 세션은 이미 끝난 세션이라 `kill_session`의 실제 동작은 검증되지 않았다.
- 인터프리터 경유: 같은 파일을 `sudo sh <파일>`로 실행하면 `TAG_HIT`이 없고, 직접 실행하면 `TAG_HIT`과 BLOCK이 난다(`쓴 지 144.244초`, `tag_ts_ns`가 같은 값). `sh` 한 번 기준이고 `python`, `node`는 확인하지 않았다 (수용한 한계 260126a).
- 탐지기 단위 테스트: 새 구역 18개. 변이로 경계(`>`를 `>=`)는 1개, 세션 비교(`!=`를 `==`)는 8개가 FAIL한다. 처음에는 만료 분기를 판정 수준만 봐서 변이를 못 잡았고, reason 문자열 검사 3개를 더해 직접 지키게 했다.
- 시나리오: `s01_write_exec_cross`(컨테이너가 쓰고 호스트가 직접 실행, BLOCK과 `would_kill` 한 번씩, write_exec_boundary의 SUSPECT 없음)와 `s02_write_exec_same_session`(같은 세션 실행, write_exec_boundary의 SUSPECT 하나, BLOCK과 `would_kill` 없음). 파일 이름은 더미 `dummy_block`과 섞이지 않게 `/tmp/payload`다.
- 러너: `sudo ./run_scenarios.sh`가 `s00`, `s01`, `s02`, `s99` 4/4 통과, `lost=0`, `writes=31`. `s01`의 `host.sh`를 `sh <파일>`로 바꾸면 FAIL해서 인터프리터 경유 미탐이 회귀 테스트로 재현된다. `s99`는 같은 세션 안 실행의 `TAG_HIT`이 한 줄 늘어 이벤트가 4줄이다 (w2d2에서 관찰).
- 러너 테스트: `s01`, `s02`를 추가하자 가짜 환경의 러너 테스트 4개가 깨졌다(시나리오가 둘뿐이라는 가정, 가짜 로그에 `TAG_HIT` 없음). `MYC_SCEN_DIR`로 격리해 21개(기존 18 + 호스트 스텝 3)가 통과한다. 변이로 컨테이너 폴더 확인과 `host.sh` 실패 확인을 각각 끄면 해당 검사 하나만 FAIL한다. 판정기 테스트는 16개 통과다.
- 한계: 실제 환경 결과는 한 번씩이다. 호스트 실행은 root(`sudo`)였다. 비root 호스트 실행, 실행 중인 세션의 파일 실행, 여러 파일, 부하 상황은 보지 않았다.

## 5. 미탐 범위 (수용한 한계와 연결)
open 시점의 쓰기 모드만 태깅하므로 rename, hardlink, mmap 쓰기, 복사 후 실행은 탐지하지 못한다. 또 `security_bprm_check`가 exec 되는 파일의 신원만 조회하므로, 에이전트가 쓴 파일이 exec 대상이 아니라 인터프리터의 인자나 설정 파일로 읽히는 실행(`sh <파일>`, `python x.py`, 설정 안의 명령)은 탐지하지 못한다 [VM확인, `sh` 한 번 기준]. `dev=40` 같은 overlay 장치 번호가 컨테이너 사이에서 재사용되면 키가 겹칠 수 있다 [확인필요]. 평가는 제한된 재현 시나리오에 기반하며 일반화는 검증되지 않았다.

## 6. 확인할 것 (3주차 이후)
1. 실제 kill과 cgroup 정리. 이미 끝난 세션에 `kill_session`을 부를 때의 동작을 정한다. 세션이 살아 있는 동안 BLOCK이 나는 시나리오가 필요하고, 그러려면 러너 B안이 먼저 필요하다 (7절 조건 1).
2. 정상 시나리오(빌드, 패키지 설치, 테스트 실행, 호스트에서 에이전트 결과물 직접 실행)를 추가해 오탐을 측정한다. 같은 세션 SUSPECT와 세션 밖 BLOCK의 빈도를 센다 (7절 조건 2).
3. 미스 경로 성능, 맵 밀려남 측정, `dev=40` 재사용 확인, 모든 exec 경로가 `security_bprm_check`를 지나는지 확인한다.
4. 호스트 비root 실행, 실행 중인 세션의 파일 실행, 여러 파일에서 같은 결과가 나오는지 본다.
5. `/workspace` bind mount는 없다. 현재 시나리오는 upperdir 경로로 대신하고, 필요 여부는 v0.2에서 정한다.
6. 더미 탐지기를 테스트 전용으로 분리할지 검토한다 (`s99`가 `dummy_block`에 의존).
7. 결정 9번은 7절에 정했다. 3주차에 실제 속도를 보고 시점을 조정할 수 있다.

## 7. 결정 9번: 경로 비교 탐지기의 시작 조건 (w2d3 확정)

용어: "경로 비교 탐지기"는 execve 시점의 최종 경로와 호출 이름의 basename 을 비교하는 탐지기다 (계획서 5절의 두 번째 탐지기, 4주차 작업). 쓰기→실행 탐지기(`write_exec_boundary`)와 다르다.

경로 비교는 유지하되(사용자 확인) 아래 조건으로 시작 여부를 미리 거른다. 계획서의 대비책(점검 시점에 쓰기→실행 탐지기와 kill switch 가 동작하지 않으면 경로 비교를 미룬다)을 점검일보다 앞당겨 적용하는 것이다. 이 프로젝트는 관측뿐 아니라 판정과 대응(차단)까지 묶는 것이 차별점이라, 탐지기 하나가 탐지에서 kill 까지 서는 것이 두 번째 탐지기보다 우선이다.

| 조건 | 시점 | 못 맞추면 |
| --- | --- | --- |
| 1 | 3주차 4일차 끝: 세션이 살아 있는 동안 BLOCK 이 나면 세션이 실제로 종료되고 cgroup 이 정리되는 시나리오(예: s03)가 러너에서 통과 | 경로 비교를 시작하지 않고 v0.2 이후로. v0.1 은 탐지기 1종으로 마무리 |
| 2 | 3주차 5일차 끝: 정상 시나리오(빌드, 패키지 설치, 테스트 실행, 호스트에서 에이전트 결과물 직접 실행)로 쓰기→실행 탐지기의 오탐 측정 | 경로 비교는 v0.2 로 |
| 3 | 경로 비교를 시작한 경우: busybox 심볼릭 링크 오탐을 허용 목록으로 다룰 수 있는지 한나절 안에 확인 | 중단하고 v0.2 로 |

- 전제: 조건 1 은 러너 B안(컨테이너가 살아 있는 동안 호스트 스텝을 실행하고 안팎을 동기화)이 먼저 필요하다. s01 은 세션이 끝난 뒤 실행(A안)이라 실제 kill 을 검증하지 못한다.
- 별도: 이미 끝난 세션에 kill_session 을 부를 때의 동작은 3주차 위험 4번(실제 kill 과 cgroup 정리)에서 정한다.
- 날짜(3주차 4일차, 5일차)는 w2 를 닫는 시점에 따라 달라지는 추정이다. 조정하면 이 절에 "w3dN 에 조정, 이유" 를 한 줄 남긴다.

## 8. 열린 설계 질문: BLOCK 의 대응 대상 (w2d3, 3주차 측정 뒤 결정)

현재 설계는 BLOCK 이면 쓴 세션(cgroup 안의 프로세스)을 종료한다(`kill_session`). 판정은 exec 이후의 사후 판정이다.

문제 제기(사용자): 에이전트가 쓴 파일을 외부 도구가 실행했을 때 에이전트를 종료하는 것이 맞는가. 외부 도구의 책임일 수도 있다.

정리: BLOCK 은 책임 판정이 아니라 신뢰 경계를 넘은 사건에 대한 격리(containment)로 설계됐다. 다만 사용자가 호스트에서 에이전트 결과물을 직접 실행하는 정상 사용도 같은 BLOCK 이 되는 오탐 가능성이 있고, 탐지기는 실행한 쪽이 누구인지 구분하지 못한다.

| 대응 대상 | 장단점 |
| --- | --- |
| 쓴 세션 종료 (현재) | 후속 행동을 중단한다. 이미 실행된 코드는 못 막고, 오탐이면 세션 전체가 죽는다 |
| 실행한 외부 프로세스 종료 | 사후에 pid 로 죽이면 이미 끝났거나 pid 가 재사용되어 엉뚱한 프로세스를 죽일 위험이 있다. 호스트 프로세스는 신뢰받는 도구로 분류되어 대응 범위 밖이다 |
| 실행 자체 거부 (커널 안) | 그 exec 한 건만 정확히 막는다. v0.3 실험 후보. 이 VM 의 활성 LSM 에 bpf 가 없다 |
| 동결 (cgroup.freeze) | 종료 없이 멈추고 검토 후 재개한다. 구현이 늘고 이 VM 에서의 동작은 확인하지 못했다 |
| kill 을 설정으로 (--no-kill 관찰 모드) | 오탐 측정에 유용하다. 기본값을 정해야 한다 |

사실 [VM확인]: `/sys/kernel/security/lsm` 은 `lockdown,capability,landlock,yama,apparmor,ima,evm` 이고 bpf 가 없다. BPF LSM 으로 커널 안 거부를 하려면 부팅 인자(`lsm=`)에 bpf 를 추가해야 할 것으로 보이며(일반 지식), 이 커널이 CONFIG_BPF_LSM 으로 빌드됐는지는 확인하지 않았다.

결정 방침: v0.1 은 쓴 세션 종료로 가고, 3주차 오탐 측정에 "호스트에서 에이전트 결과물을 직접 실행하는 정상 시나리오"를 넣어 BLOCK 이 얼마나 나는지 센다. 측정 뒤 대응 대상을 정한다. README 한계 섹션에는 BLOCK 이 책임 판정이 아니라 격리이며 정상 사용에서도 발생할 수 있다는 점을 명시한다. 한계 목록에는 올리지 않는다 (열린 질문이다).
