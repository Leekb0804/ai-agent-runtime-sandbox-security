# 세션 로그 스키마 (초안, schema_version 0)

5주차에 스키마를 확정하면서 `schema_version`을 1로 올린다. 그 전에는 필드가 바뀔 수 있다.

## 파일 구조

```
/var/lib/mycontainer/sessions/
  by-cgroup/<cgroup_id>  ->  ../<세션ID>     # run_container.sh 가 세션 시작 때 만드는 링크
  <세션ID>/
    meta.json                                  # 세션 정보 (agent-run 이 기록)
    events.jsonl                               # 커널이 보낸 이벤트 (로더가 기록)
    verdicts.jsonl                             # 판정과 대응 (로더가 기록)
  _unattributed/                               # 세션을 못 찾은 이벤트/판정 (버리지 않고 모음)
```

- 파일은 한 줄에 JSON 하나(JSON Lines)이고 append 전용이다. 권한은 0600.
- 로그는 호스트의 로더가 호스트 경로에 기록한다. 컨테이너 안의 에이전트는 쓸 수 없다.
- 문자열 값(파일 경로 등)은 모두 이스케이프된다 (로그 위조 방지).

## 공통 필드 (모든 레코드)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `schema_version` | 정수 | 로그 형식 버전 (지금 0) |
| `type` | 문자열 | `event` / `verdict` / `action` |
| `session` | 문자열 | 세션 ID. 못 찾았으면 `_unattributed` |
| `logged_at_ms` | 정수 | 로그를 쓴 시각 (벽시계, epoch ms). 이벤트 발생 시각이 아님 |

## event (events.jsonl)

| 필드 | 설명 |
| --- | --- |
| `event.kind` | `EXEC` / `WRITE` / `OPEN` / `DNS` / `UNKNOWN` |
| `event.pid` | 이벤트를 일으킨 프로세스 (exec 는 PID 를 유지하므로 pid 만으로 프로세스를 구분하면 안 됨) |
| `event.cgroup_id` | 이벤트가 발생한 cgroup id |
| `event.ts_ns` | 발생 시각. 부팅 후 경과 나노초(단조 시계). 벽시계와의 변환은 5주차 |
| `event.filename` | EXEC 일 때만. 최대 256바이트, 길면 잘림 |

## verdict (verdicts.jsonl)

event 의 필드에 더해 다음이 있다. `event` 객체는 판정의 원인이 된 이벤트다.

| 필드 | 설명 |
| --- | --- |
| `level` | `SUSPECT` (기록만) / `BLOCK` (종료 요청) |
| `detector` | 판정을 낸 탐지기 이름 (디스패처가 채움) |
| `reason` | 사람이 읽을 이유 (최대 127자) |

## action (verdicts.jsonl)

판정에 따른 대응 기록. BLOCK 이면 세션 cgroup 의 종료를 시도하고 그 결과를 한 줄 남긴다 (w3d2 부터. 그 전에는 스텁의 `would_kill`).
종료는 세션 ID 끝의 숫자로 `/sys/fs/cgroup/mycontainer-<숫자>` 를 찾고, 디렉토리 inode 가 `cgroup_id` 와 같을 때만 `cgroup.kill` 에 `1` 을 쓴다.

| 필드 | 설명 |
| --- | --- |
| `cgroup_id` | 대상 세션의 cgroup |
| `action` | `kill` (`would_kill` 은 나중의 평가용 관찰 모드에 쓰려고 비워 둔다) |
| `result` | 종료 시도의 결과 (아래 표) |
| `detail` | 어느 단계에서 끝났는지: `written`, `enoent`, `inode_mismatch`, `bad_session_id`, `open_root`, `open_dir`, `fstat`, `open_kill`, `write`, `unattributed` |
| `errno` | 실패한 호출의 errno. 없으면 0 |
| `reason` | 대응을 일으킨 판정의 reason |

| `result` | 의미 | 다음 BLOCK 때 |
| --- | --- | --- |
| `sent` | `cgroup.kill` 에 썼다. 로더가 그 cgroup 을 `session_cgroups` 맵에서 지운다 | 다시 시도하지 않음 |
| `already_gone` | 대상이 없다. 디렉토리가 없거나(`enoent`) 같은 이름의 다른 cgroup 이다(`inode_mismatch`, 아무것도 쓰지 않음) | 다시 시도하지 않음 |
| `failed` | 그 밖의 실패 (잘못된 세션 ID, 권한, 쓰기 오류 등). `errno` 를 남긴다 | 다시 시도함 |
| `skipped` | 세션을 찾지 못해(`_unattributed`) 대상 cgroup 을 알 수 없어 시도하지 않았다 | 다시 시도하지 않음 |

한 세션에서 BLOCK 이 여러 번 나와도 `action` 은 한 번만 기록된다 (`failed` 일 때만 다음 BLOCK 에서 다시 시도해 한 줄이 더 남는다).

## 샘플 (실제 코드가 만든 출력)

```json
{"schema_version":0,"type":"event","session":"20261002-115607-1095185","logged_at_ms":1791260904853,"event":{"kind":"EXEC","pid":1095282,"cgroup_id":309013,"ts_ns":2061872220461627,"filename":"/tmp/trigger"}}
{"schema_version":0,"type":"verdict","session":"20261002-115607-1095185","logged_at_ms":1791260904853,"level":"BLOCK","detector":"dummy_block","reason":"dummy: /tmp/trigger 실행","event":{"kind":"EXEC","pid":1095282,"cgroup_id":309013,"ts_ns":2061872220461627,"filename":"/tmp/trigger"}}
{"schema_version":0,"type":"action","session":"20261002-115607-1095185","logged_at_ms":1791260904853,"cgroup_id":309013,"action":"kill","result":"sent","detail":"written","errno":0,"reason":"dummy: /tmp/trigger 실행"}
```

(마지막 action 줄은 실제 출력이 아니라, 같은 로그의 `would_kill` 줄을 w3d2 형식으로 손으로 고친 예이다.)

## 알려진 한계 (한계 목록에 반영할 것)

- 로그 쓰기가 동기식이라 디스크가 막히면 수신 루프도 멈춘다. 로더 종료 시 출력하는 `log stats`의 `slow`/`max`로 확인한다.
- 쓰기 실패는 `lost` 로 세기만 한다. 리포트에 표시하는 것은 5주차.
- cgroup_id -> 세션 대응은 캐시되며 다시 확인하지 않는다. cgroup id 가 재사용되면 잘못 기록될 수 있다.
- 세션 슬롯이 64개를 넘으면 가장 오래 안 쓴 세션의 파일을 닫는다. 이때 그 세션의 `kill_requested` 플래그도 사라져 같은 세션에서 BLOCK 이 다시 오면 종료 시도가 한 번 더 나간다. 그 cgroup 이 이미 없으면 `already_gone` 으로 기록되고, 아직 있으면 `sent` 가 다시 나갈 수 있다.
- 파일에 쓰기 전 로더가 죽으면 버퍼에 있던 마지막 기록이 사라질 수 있다 (`fflush` 는 하지만 `fsync` 는 하지 않음).
