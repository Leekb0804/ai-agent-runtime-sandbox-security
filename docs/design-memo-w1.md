# 설계 메모 (v0.1 1주차)

1주차에 만든 "관측 → 판정 → 기록" 배관의 구조와, 2주차 이후로 넘기는 결정을 한 장에 모은다.
이 문서는 코드와 어긋나면 코드가 맞다. 어긋난 곳을 발견하면 이 문서를 고친다.

- 로그 레코드의 필드 정의: [`log-schema-draft.md`](log-schema-draft.md)
- 알려진 한계와 해결 시점: [`week1-notes.md`](week1-notes.md)

## 1. 한 줄 요약

AI 코딩 에이전트가 도는 컨테이너(세션)를 커널(eBPF)에서 관측하고, 에이전트의 출력이 닿지 않는 곳에서
규칙으로 판정해서 세션별 로그에 남긴다. 확실한 위험(`BLOCK`)만 세션 종료를 요청하고, 애매한 것(`SUSPECT`)은 기록만 한다.
1주차에는 탐지 로직 없이 이 배관이 끝까지 통하는 것만 만들었다 (더미 탐지기 2개).

## 2. 데이터가 흐르는 길

```
[agent-run]  run_container.sh -> mycontainer_run
   │  cgroup 을 만들고, cgroup id 를 BPF map(session_cgroups)에 등록한 뒤 clone -> exec
   │  sessions/by-cgroup/<cgroup_id> -> ../<세션ID> 링크를 만들어 둔다
   ▼
[커널]  watcher.bpf.c   sys_enter_execve tracepoint
   │  map 에 등록된 cgroup 의 execve 만 골라 ring buffer(events)에 기록
   ▼
[로더]  myc_loader      (세션과 무관하게 계속 떠 있는 감시자)
   │  handle_event      이벤트를 받아 세션을 찾고(session_get) events.jsonl 에 기록
   ▼
   dispatch_event       길이/종류 검증 후, 그 종류를 구독한 탐지기에게만 전달
   ▼
   탐지기들             on_event(이벤트) -> 판정 없음 / SUSPECT / BLOCK
   ▼
   handle_verdict       verdicts.jsonl 에 기록 -> BLOCK 이면 kill_session (세션당 한 번, 지금은 스텁)
```

판정은 전부 에이전트 바깥(로더와 커널)에서 일어난다. 에이전트의 출력이 판정에 영향을 줄 경로가 없다.

## 3. 구성 요소

| 구성 요소 | 위치 | 역할 |
| --- | --- | --- |
| agent-run | `src/run_container.sh`, `src/mycontainer_run.c` | 컨테이너 실행, 세션 ID 와 `meta.json`, cgroup id 등록, by-cgroup 링크 |
| 이벤트 형식 | `src/bpf/event.h` | 커널과 유저가 공유하는 이벤트 구조체 (공통 헤더 + 종류별 payload) |
| 관측 | `src/bpf/watcher.bpf.c` | execve 관측, cgroup 필터, ring buffer 로 전달 |
| 로더 | `src/loader/loader.c` | eBPF 로드/attach, ring buffer 수신, 종료 시 `log stats` |
| 디스패처 | `src/loader/dispatcher.*` | 탐지기 등록과 분배, 오류 격리, sink 호출 |
| 탐지기 | `src/loader/detectors/*.c` | 판단 함수. 파일을 넣으면 스스로 등록 (`constructor`) |
| 판정 수집기 | `src/loader/verdict_handler.*` | 기록 후 대응. 모든 판정이 거치는 단 하나의 지점 |
| 세션 로그 | `src/loader/session_log.*`, `jsonl.*` | cgroup id -> 세션 변환, 세션별 파일 기록, JSON 한 줄 생성 |
| kill switch | `src/loader/kill.*` | 인터페이스 확정. 지금은 `would_kill` 만 기록하는 스텁 |
| 시나리오 러너 | `run_scenarios.sh`, `scenarios/`, `tools/` | 시나리오를 실제로 돌려 세션 로그를 기대값과 비교 |

## 4. 핵심 인터페이스

### 4.1 이벤트 (`event.h`)

모든 이벤트는 같은 헤더로 시작하고 뒤에 종류별 payload 가 붙는다. ring buffer 는 타입을 모르는 바이트 통로라서
`kind` 와 길이 검증이 읽는 쪽의 책임이다.

| 필드 | 설명 |
| --- | --- |
| `kind` | `EVT_EXEC`(구현됨), `EVT_WRITE`, `EVT_OPEN`, `EVT_DNS`(예정) |
| `pid`, `cgroup_id`, `ts_ns` | 누가, 어느 세션에서, 언제 (`ts_ns` 는 부팅 후 경과 나노초) |
| `payload_len` | 헤더 뒤 payload 길이 |

호환 규칙: 기존 필드의 순서와 크기를 바꾸지 않고 새 필드는 뒤에만 추가한다. 이벤트 구조체의 첫 필드는 항상 헤더다.
한 ring buffer 에 여러 종류를 섞어 보내는 이유는 이벤트 간 시간 순서를 보존하기 위해서다 (쓰기→실행 상관 탐지에 필요).

### 4.2 탐지기 (`detector.h`)

```c
struct detector {
    const char *name;
    __u32 kinds;                 // 구독할 이벤트 종류의 비트마스크 (KIND_BIT(EVT_EXEC) | ...)
    int (*on_event)(const struct event_hdr *h, size_t len, struct verdict *out);
};
// on_event 반환: 1 = 판정 있음(out 을 채움), 0 = 판정 없음, 음수 = 탐지기 내부 오류
```

탐지기 작성 규칙:

- 판단만 한다. 출력, 로그, 종료는 하지 않는다 (판정 수집기가 한 곳에서 처리).
- `h` 는 ring buffer 메모리를 직접 가리킨다. 함수가 끝나면 덮어쓰이므로 나중에 필요한 값은 복사해 둔다.
- 탐지기끼리 호출 순서에 의존하지 않는다 (순서는 링크 순서라 보장되지 않는다).
- 이벤트를 해석하기 전에 `len` 을 확인한다.
- 같은 pid 에서 서로 다른 프로그램의 이벤트가 연달아 올 수 있다 (exec 는 PID 를 유지한다). pid 만으로 프로세스를 구분하지 않는다.

### 4.3 판정과 대응

| 판정 | 처리 | 이유 |
| --- | --- | --- |
| `SUSPECT` | 기록만 | 정상 작업과 구분이 어려워서 멈추면 과잉 차단 |
| `BLOCK` | 기록 후 세션 종료 요청 (세션당 한 번) | 확실한 위험 |

기록이 대응보다 먼저다 (대응이 실패해도 판단 근거는 남는다). `BLOCK` 이후에도 그 세션의 이벤트 기록은 계속된다.
기본값은 "BLOCK 이면 종료"이고, 오탐 측정용 관찰 모드는 3주차에 검토한다 (평가용으로만).

## 5. 세션과 로그

세션은 프로세스도 감시 프로그램도 아니다. `agent-run` 한 번이 만든 cgroup 과 그 안의 모든 프로세스, 그 기록에 붙인 이름표다.
로더는 세션 바깥에서 계속 떠 있다.

```
/var/lib/mycontainer/sessions/
  by-cgroup/<cgroup_id>  ->  ../<세션ID>       # cgroup id -> 세션 대응표 (심볼릭 링크)
  <세션ID>/
    meta.json            # 세션 정보 (agent-run 이 기록)
    events.jsonl         # 커널이 본 이벤트
    verdicts.jsonl       # 판정과 대응
  _unattributed/         # 세션을 못 찾은 기록 (버리지 않고 모음)
```

- 세션 ID 는 `시작 시각-스크립트 PID` 이다. cgroup id 는 cgroup 이 사라지면 의미가 없어지는 커널 쪽 키라서 로그의 이름으로 쓰지 않는다.
  모든 레코드에 세션 ID 를 직접 넣는다.
- 세션을 못 찾아도 로그를 버리지 않는다. 이벤트의 cgroup id 로 나중에 추적한다.
- 로그는 호스트의 로더가 호스트 경로에 쓴다 (권한 0600). 컨테이너 안의 에이전트는 쓸 수 없다.

## 6. 시나리오와 러너

```
scenarios/<이름>/run.sh        컨테이너 안에서 실행할 스크립트 (/bin/sh -c 로 실행됨)
scenarios/<이름>/expect.json   기대하는 세션 로그
```

- `expect.json` 은 레코드 필터(`match`)와 개수 조건(`count` 또는 `min`/`max`)의 목록이다. 형식은 `tools/judge.sh` 의 설명 참고.
- 판정기는 세션 폴더의 `events.jsonl` 과 `verdicts.jsonl` 을 합쳐서 본다. 양성 검사를 이벤트(커널이 본 사실)로 쓰면 탐지기가 바뀌어도 시나리오가 유지된다.
- **양성 검사가 하나도 없는 `expect.json` 은 거부한다.** 음성 검사("BLOCK 이 없어야 한다")만 있으면 아무것도 관측하지 못한 빈 로그도 통과한다.
- 러너는 전용 로더와 임시 세션 루트를 쓴다 (개발용 로그를 더럽히지 않음). 시작 전에 환경을 점검하고, 틀리면 종료 코드 2 로 멈춘다 (실패 1 과 구분).
- 인프라 검증: 로그 유실 `lost=0`, `_unattributed` 비어 있음.
- 시나리오 규칙: 명령은 경로를 명시한다 (busybox 내장 명령은 execve 가 없어 관측되지 않을 수 있다). 실제 위험한 동작은 하지 않고 마커 파일 생성으로 치환한다.
- `s00~s98` 은 실제 시나리오, `s99_dummy_block` 은 더미 탐지기 배관 검증용이다.

검증 도구는 세 층이다.

| 도구 | 확인하는 것 | 필요한 것 |
| --- | --- | --- |
| `tools/test_judge.sh` | 로그를 기대값과 비교하는 판정 로직 (실제 로그 + 일부러 깨뜨린 로그) | 없음 |
| `tools/test_runner.sh` | 러너의 흐름 (가짜 로더와 가짜 agent-run) | 없음 |
| `sudo ./run_scenarios.sh` | 진짜 로더와 컨테이너로 전체 | root, 빌드 결과물 |

## 7. 알려진 한계

[`week1-notes.md`](week1-notes.md) 가 원본이다. 이 문서에 특히 영향을 주는 것만 옮긴다.

- 사후 차단이다 (exec 이후에 판정). 세션 밖에서 이미 실행된 프로세스는 종료 대상이 아니다.
- busybox 내장 명령은 execve 가 없어 커널에서 관측할 수 없다.
- 탐지기가 세그폴트를 내면 로더 전체가 죽는다 (프로세스 분리는 v0.1 범위 밖).
- 탐지기가 연속 오류로 꺼지거나 등록에 실패하면 조용히 빠진다 (fail-open). kill switch 설계 때 정책을 정한다.
- ring buffer 유실을 세지 않는다 (드롭 카운터 없음).
- 로그 쓰기가 동기식이다. 지금 측정은 14회 기록 기준(`max=104us`)이라 부하 시험 전이다.

## 8. 2주차로 넘기는 결정

2주차의 목표는 첫 진짜 탐지기인 "쓰기→실행 경계 추적"이다. 월요일에 아래를 정한다.

| 결정 | 선택지 | 메모 |
| --- | --- | --- |
| 위협 모델 | "에이전트 바깥 프로세스"가 컨테이너 안 파일에 접근하는 경로 | 호스트와 공유되는 workspace(bind mount)나 overlay upperdir. 호스트의 신뢰받는 도구는 그 경로의 파일을 실행하는 스크립트로 흉내 낸다 |
| 쓰기 후킹 지점 | `security_file_open` (FMODE_WRITE 검사) / `vfs_write` | 전자는 쓰기 모드 open 시점이라 부하가 작다. 첫 선택 |
| exec 후킹 지점 | `security_bprm_check` / `sched_process_exec` | 커널 심볼이 없거나 인라인되면 tracepoint 로 전환 |
| 태깅 키 | `(s_dev, i_ino)` + `{cgroup_id, ts_ns}` | overlayfs 에서 inode 가 호스트와 컨테이너에서 같게 보이는지 **화요일 첫 1시간에 먼저 검증** |
| map 정책 | `LRU_HASH` 10240 개, 조회 시 10분 넘으면 무시 | 임계값은 상수로 분리 |
| 필터 변경 | 쓰기 probe 는 세션 cgroup 만, exec probe 는 전체 cgroup 을 보고 map 히트만 emit | 1주차의 "세션 cgroup 일 때만 emit"이 바뀐다. 유저 쪽 탐지기가 세션 cgroup 을 따로 걸러야 한다 |
| 더미 탐지기 | `dummy_suspect` 는 모든 EXEC 를 의심하므로 실제 탐지기와 함께 두면 SUSPECT 가 폭증 | 2주차에 제거하거나 빌드 옵션으로 분리. 시나리오는 이벤트 기반 양성 검사라 영향이 없다. `s99` 는 `dummy_block` 이 있는 동안만 유효하다 |
| 시나리오에 호스트 동작이 필요 | 세션이 살아 있는 동안 호스트에서 파일을 실행해야 한다 | `run.sh` 를 컨테이너 안에서 기다리게 하고 `host.sh` 를 동시에 실행하는 확장 필요 (러너 설계 변경) |

## 9. 2주차 월요일 첫 작업

1. 위 표의 위협 모델과 후킹 지점을 확정하고 설계 메모를 갱신한다.
2. `event.h` 에 `EVT_TAG_HIT` payload(태그 소유 cgroup, 태그 시각, 실행자 cgroup, 경로) 초안을 추가한다 (기존 필드는 건드리지 않는다).
3. 시나리오 s01(에이전트가 쓴 마커 파일을 바깥 프로세스가 실행)의 `host.sh` 형식을 정한다.
