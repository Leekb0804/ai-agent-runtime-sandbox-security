# 세션 로그 스키마 (schema_version 1)

5주차(w5d1)에 schema_version 을 1 로 올렸다. 4주차까지의 출력(초안)은 0 이다.

## 파일 구조

```
/var/lib/mycontainer/sessions/
  by-cgroup/<cgroup_id>  ->  ../<세션ID>     # run_container.sh 가 세션 시작 때 만드는 링크
  <세션ID>/
    meta.json                                  # 세션 정보 (agent-run 이 기록, 아래 "meta.json" 절)
    events.jsonl                               # 커널이 보낸 이벤트 (로더가 기록)
    verdicts.jsonl                             # 판정과 대응 (로더가 기록)
  _unattributed/                               # 세션을 못 찾은 이벤트/판정 (버리지 않고 모음)
```

- 파일은 한 줄에 JSON 하나(JSON Lines)이고 append 전용이다. 권한은 0600.
- 로그는 호스트의 로더가 호스트 경로에 기록한다. 컨테이너 안의 에이전트는 쓸 수 없다.
- 문자열 값(파일 경로 등)은 모두 이스케이프된다 (로그 위조 방지).

## meta.json (세션 정보)

agent-run(`src/run_container.sh agent-run`)이 세션을 시작할 때 만들고, 정리 단계에서 `ended_at` 과 `exit_code` 를 더한다. JSON Lines 가 아니라 객체 하나다. `run` 모드에서는 만들지 않는다.

| 키 | 타입 | 쓰는 때 | 설명 |
| --- | --- | --- | --- |
| `session_id` | 문자열 | 시작 | 세션 ID (`시작 시각-스크립트 PID`) |
| `cgroup_id` | 정수 | 시작 | 세션 cgroup 의 id (디렉토리 inode) |
| `started_at` | 문자열 | 시작 | `date -Is` 의 출력 (초 단위, 시간대 포함) |
| `command` | 문자열 | 시작 | 실행한 명령. `"${CMD[*]}"` 로 인자를 공백으로 합친 것이라 인자 경계가 사라지고 개행이 들어갈 수 있다. 러너 세션은 `run.sh` 전체(주석 포함)가 들어가 길다 |
| `schema_version` | 정수 | 시작 | meta.json 형식 버전 (지금 1). 로그의 `schema_version` 과 함께 올린다. 자동으로 연결되지는 않는다 |
| `rootfs` | 문자열 | 시작 | 쓴 rootfs 경로. 준 그대로라 상대 경로일 수 있다 (`MYC_ROOTFS` 로 준 경우만 절대 경로를 검사한다) |
| `cgroup_path` | 문자열 | 시작 | 스크립트 변수 `CGROUP_PATH` 의 값 (`/sys/fs/cgroup/mycontainer-<PID>`) |
| `limits` | 객체 | 시작 | `memory`, `cpu`, `pids` 세 문자열. 기본값은 모두 `"max"`. `cpu` 는 사용자가 준 값이다 (`cpu.max` 에 쓴 변환값이 아님) |
| `ended_at` | 문자열 | 종료 | 정리 단계 끝의 `date -Is` |
| `exit_code` | 정수 | 종료 | agent-run 의 종료 코드. 의미는 아래 "exit_code 의 의미" 절 |

- 권한은 0600, 소유자는 root 다 (jsonl 과 같다). 정리 단계는 임시 파일을 만들어 600 으로 맞춘 뒤 `mv` 로 바꿔 넣으므로 갱신 뒤에도 600 이 유지된다 [VM확인, 한 번].
- 시작 때 jq 가 실패하면 경고만 내고 meta.json 없이 세션이 진행된다 [모래상자 확인].
- 정리 단계의 jq 가 실패하면 `ended_at` 과 `exit_code` 가 없는 채로 남는다 [추론].

## exit_code 의 의미

meta.json 의 `exit_code` 는 agent-run 의 종료 코드다. 정상 경로에서는 `mycontainer_run` 의 종료 코드이고, TERM/INT 를 받으면 trap 이 정한 값이다. 서로 다른 원인이 같은 값이 되는 경우가 많아 값만으로 원인을 가릴 수 없다.

| 값 | 나오는 경로 | 구분하지 못하는 것 |
| --- | --- | --- |
| 0 | 컨테이너 PID 1 이 0 으로 끝남 | |
| 1 | PID 1 이 신호로 죽음 (`mycontainer_run` 이 1 을 돌려줌. PID 1 만 죽을 때이고, `cgroup.kill` 로 죽으면 `mycontainer_run` 도 죽어 137), `mycontainer_run` 의 `die()`, 로더가 없음, 인자 부족, 에이전트 스크립트가 1 로 끝남 | 이 다섯 경우를 서로 구분하지 못한다 |
| 그 밖의 값 (2~125, 126, 127 등) | PID 1 의 종료 코드가 그대로 전달됨 (예: 명령을 못 찾으면 sh 가 127) | 에이전트 자신의 종료 코드와 섞인다 |
| 124 | 러너가 `timeout` 으로 감싼 agent-run 의 종료 코드다 (그때 meta.json 은 143). `timeout` 자신의 124 는 meta.json 에 나오지 않는다 | 에이전트가 직접 124 로 끝나면 meta.json 에도 124 가 나온다 (위 "그 밖의 값" 행) |
| 130 | INT trap. 러너 B안(& 로 띄움)에서는 INT trap 이 효과가 없다 | 에이전트가 130 으로 끝난 경우 [추론] |
| 137 | `mycontainer_run` 이 SIGKILL 로 죽음 (128+9) [추론]. 로더의 `cgroup.kill`, 외부 `cgroup.kill`·`kill -9`, 러너 정리의 `cgroup.kill` | 이 경로들을 서로 구분하지 못한다 |
| 143 | TERM trap (러너의 timeout 포함) | 외부 TERM, 그룹 TERM |
| 255 | `mycontainer_run` 의 `return -1` (cgroup 경로 stat 실패) [추론] | |
| 키 없음 | run_container.sh 의 bash 가 SIGKILL 로 죽음, `set -e` 로 `mycontainer_run` 전에 끝남, 정리 단계의 jq 실패 | 리포트는 "종료 정보 없음" 으로 표시한다 |

로그에서 로더가 세션 종료를 요청한 경우를 가려낼 수 있는 단서는 verdicts.jsonl 의 `action=kill`, `result=sent` 레코드뿐이다. meta.json 에는 종료 원인을 구분하는 필드가 없다.

## 공통 필드 (모든 레코드)

| 필드 | 타입 | 설명 |
| --- | --- | --- |
| `schema_version` | 정수 | 로그 형식 버전 (지금 1. 4주차까지의 출력은 0) |
| `type` | 문자열 | `event` / `verdict` / `action` |
| `session` | 문자열 | 세션 ID. 못 찾았으면 `_unattributed` |
| `logged_at_ms` | 정수 | 로그를 쓴 시각 (벽시계, epoch ms). 이벤트 발생 시각이 아님 |

- 정수 필드는 부호 없는 64비트(`%llu`)로 쓴다. double 로 읽는 도구에서는 2^53 을 넘는 값의 끝자리가 바뀔 수 있다 (`ts_ns` 는 부팅 후 약 104일에 넘는다).

## event (events.jsonl)

| 필드 | 설명 |
| --- | --- |
| `event.kind` | `EXEC` / `WRITE` / `OPEN` / `DNS` / `TAG_HIT` / `EXEC_PATH` / `UNKNOWN` |
| `event.pid` | 이벤트를 일으킨 프로세스 (exec 는 PID 를 유지하므로 pid 만으로 프로세스를 구분하면 안 됨) |
| `event.cgroup_id` | 이벤트가 발생한 cgroup id |
| `event.ts_ns` | 발생 시각. 부팅 후 경과 나노초(단조 시계). 벽시계와의 변환은 5주차 |
| `event.filename` | EXEC, TAG_HIT, EXEC_PATH 일 때. exec 요청 이름(`bprm->filename` 또는 execve 인자). 최대 256바이트, 길면 잘림 |
| `event.final_name`, `event.parent_name`, `event.grandparent_name` | EXEC_PATH 일 때만. `security_bprm_check` 에서 본 실행 파일의 최종 dentry 이름과 부모·조부모 이름. 각 64바이트 칸이라 63바이트에서 잘림. 컨테이너 안 경로는 overlay 기준(`/tmp/payload` → payload, tmp, `/`) |
| `event.exec_cgroup_id`, `event.tag_ts_ns`, `event.tag_write_count`, `event.dev`, `event.ino` | TAG_HIT 일 때만. TAG_HIT 의 `event.cgroup_id` 는 실행자가 아니라 파일을 쓴 세션의 cgroup 이다 (design-memo-w2 3.2절) |

### 필드 생략과 예외

- `event` 객체는 항상 `kind`, `pid`, `cgroup_id`, `ts_ns` 네 칸으로 시작한다. kind 별 추가 필드는 이벤트 길이가 그 구조체 크기 이상일 때만 붙는다. 길이가 모자라면 네 칸만 남는다.
- TAG_HIT 의 필드 순서는 `exec_cgroup_id`, `tag_ts_ns`, `tag_write_count`, `dev`, `ino`, `filename` 이다 (`filename` 이 맨 뒤).
- 예외: TAG_HIT 의 `cgroup_id` 는 파일을 쓴 세션의 cgroup 이고, 실행한 쪽은 `exec_cgroup_id` 다. 그래서 TAG_HIT 와 그 판정은 실행한 세션이 아니라 쓴 세션의 로그에 남는다.
- `WRITE`, `OPEN`, `DNS` 는 kind 번호만 정의되어 있고(예약) 지금은 출력되지 않는다. 실제로 나오는 kind 는 `EXEC`, `TAG_HIT`, `EXEC_PATH` 이고, 모르는 번호는 `UNKNOWN` 으로 쓴다.
- EXEC 와 EXEC_PATH 는 1:1 이 아니다. 같은 세션 로그에서 EXEC 와 EXEC_PATH 의 개수가 다를 수 있다 (w5d1 VM 실측 한 번: n03 18/16, n05 6/7). 원인은 스크립트 실행 때 `security_bprm_check` 가 두 번 불리는 것과 실패한 execve 도 EXEC 로 남는 것으로 본다 [추론].

## verdict (verdicts.jsonl)

event 의 필드에 더해 다음이 있다. `event` 객체는 판정의 원인이 된 이벤트다.

| 필드 | 설명 |
| --- | --- |
| `level` | `SUSPECT` (기록만) / `BLOCK` (종료 요청). `UNKNOWN` 은 코드의 기본값일 뿐 나오지 않는다 |
| `detector` | 판정을 낸 탐지기 이름 (디스패처가 채움) |
| `reason` | 사람이 읽을 이유. 최대 127바이트 (NUL 포함 128바이트 버퍼). 바이트 단위로 잘리므로 UTF-8 문자 중간에서 끊길 수 있다. 아래 "reason 의 계약" |

코드 주석(`detector.h` 의 reason 필드, `exec_identity.c` 의 이유 길이 설명)에는 아직 "127자" 로 적혀 있지만 한도는 글자가 아니라 바이트다.

### reason 의 계약

reason 은 사람이 읽는 문장이지만, 아래 접두어와 문구는 리포트가 판정 종류를 가리는 데 쓰는 계약으로 본다. 문구를 바꾸면 이 표와 리포트를 함께 고친다.

| 탐지기 | level | reason 의 시작 |
| --- | --- | --- |
| `exec_identity` | SUSPECT | `[M] 메모리에서 실행(memfd): 요청 <이름>, 실제 <이름>` |
| `exec_identity` | SUSPECT | `[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 <basename>, 실제 <이름> (위치 <임시 위치>)` |
| `write_exec_boundary` | BLOCK | `세션 밖 실행, 쓴 지 <초>.<밀리초>초: <경로>` |
| `write_exec_boundary` | SUSPECT | `세션 밖 실행, 태그 만료, 쓴 지 <초>.<밀리초>초: <경로>` |
| `write_exec_boundary` | SUSPECT | `같은 세션 안 실행, 쓴 지 <초>.<밀리초>초: <경로>` |
| `dummy_block` (시험용) | BLOCK | `dummy: /tmp/trigger 실행` |
| `dummy_suspect` (시험용) | SUSPECT | `dummy: 모든 EXEC 는 의심` |

이번 샘플(w5d1) 세션에 없는 문구: [M] 규칙, 태그 만료, dummy_block (코드 기준)

BLOCK 문구와 태그 만료 문구는 둘 다 `세션 밖 실행, ` 으로 시작하므로, 맞춰 볼 때는 BLOCK 은 `세션 밖 실행, 쓴 지`, 만료는 `세션 밖 실행, 태그 만료, 쓴 지` 로 확인한다. 쉼표로 나눠 규칙을 고르면 안 되고 앞에서부터 문구 전체를 맞춰 본다. 이 계약은 단위 시험으로 고정되어 있다 (`src/loader/test_write_exec_boundary.c`, `src/loader/test_exec_identity.c`, `src/loader/test_dummy_detectors.c`). 문구를 바꾸면 이 시험이 FAIL 한다. 태그 만료와 같은 세션 문구는 접두어만 시험하고, 그 뒷부분(`<초>.<밀리초>초: <경로>`)은 같은 형식 문자열을 쓰는 BLOCK 문구의 전체 문장 시험이 함께 지킨다 [추론].

## action (verdicts.jsonl)

판정에 따른 대응 기록. BLOCK 이면 세션 cgroup 의 종료를 시도하고 그 결과를 한 줄 남긴다 (w3d2 부터. 그 전에는 스텁의 `would_kill`).
종료는 세션 ID 끝의 숫자로 `/sys/fs/cgroup/mycontainer-<숫자>` 를 찾고, 디렉토리 inode 가 `cgroup_id` 와 같을 때만 `cgroup.kill` 에 `1` 을 쓴다.
로더를 평가용 관찰 모드(`--no-kill`)로 띄우면 종료하지 않고 `action=would_kill`, `result=not_sent`, `detail=observe_mode`, `errno=0` 한 줄만 남긴다. 세션을 찾지 못한 경우(`_unattributed`)는 관찰 모드에서도 `kill` / `skipped` 그대로다.

| 필드 | 설명 |
| --- | --- |
| `cgroup_id` | 대상 세션의 cgroup |
| `action` | `kill` (종료를 시도함) / `would_kill` (관찰 모드. 종료했을 것이라는 기록만) |
| `result` | 종료 시도의 결과 (아래 표) |
| `detail` | 어느 단계에서 끝났는지: `written`, `enoent`, `inode_mismatch`, `bad_session_id`, `open_root`, `open_dir`, `fstat`, `open_kill`, `write`, `unattributed`, `observe_mode` (관찰 모드) |
| `errno` | 실패한 호출의 errno. 없으면 0 |
| `reason` | 대응을 일으킨 판정의 reason |

| `result` | 의미 | 다음 BLOCK 때 |
| --- | --- | --- |
| `sent` | `cgroup.kill` 에 썼다. 로더가 그 cgroup 을 `session_cgroups` 맵에서 지운다 | 다시 시도하지 않음 |
| `already_gone` | 대상이 없다. 디렉토리가 없거나(`enoent`) 같은 이름의 다른 cgroup 이다(`inode_mismatch`, 아무것도 쓰지 않음) | 다시 시도하지 않음 |
| `failed` | 그 밖의 실패 (잘못된 세션 ID, 권한, 쓰기 오류 등). `errno` 를 남긴다 | 다시 시도함 |
| `skipped` | 세션을 찾지 못해(`_unattributed`) 대상 cgroup 을 알 수 없어 시도하지 않았다 | 다시 시도하지 않음 |
| `not_sent` | 관찰 모드라 `cgroup.kill` 에 쓰지 않았다 (`action=would_kill`). `session_cgroups` 맵에서도 지우지 않는다 | 다시 시도하지 않음 |

한 세션에서 BLOCK 이 여러 번 나와도 `action` 은 한 번만 기록된다 (`failed` 일 때만 다음 BLOCK 에서 다시 시도해 한 줄이 더 남는다).

### verdict 와의 연결

action 줄은 세션의 첫 BLOCK verdict 줄 바로 다음 줄에 있고, `reason` 이 그 verdict 의 `reason` 과 같다 (w5d1 샘플 s04, n06 에서 확인). 로더는 한 스레드에서 판정을 먼저 쓰고(fflush), 곧바로 종료를 시도해 같은 파일에 action 을 쓴다 (`verdict_handler.c` 에서 `session_write_verdict` 다음에 `kill_session`).

- 그 뒤의 BLOCK 다음 줄에는 action 이 없다. 다만 `failed` 였으면 다음 BLOCK 의 바로 다음 줄에 한 줄이 더 생긴다 [추론, 샘플에 없음].
- 세션 칸이 밀려났다가 다시 열린 세션에서는 뒤의 BLOCK 다음에도 action 이 생길 수 있다. 이 문서 "알려진 한계" 절의 세션 칸 항목(세션 슬롯이 64개를 넘을 때)이다 [추론, 샘플에 없음].
- verdicts.jsonl 을 열지 못한 세션에서는 verdict 와 action 이 함께 빠지고 `lost` 로만 세어진다 [추론, 샘플에 없음]. 이때도 종료 시도는 일어난다 [추론].
- 이 순서는 verdicts.jsonl 안의 순서다. 화면 출력(stdout 의 판정, stderr 의 `[kill]` 알림)의 순서와는 다르다.

## 샘플 (실제 코드가 만든 출력)

아래는 w5d1 VM 에서 러너가 만든 세션 로그를 줄 그대로 옮긴 것이다 (schema_version 1). 줄은 각 파일의 원래 순서다.

(a) 세션 밖 실행 BLOCK 과 종료 (s04, 살아 있는 세션). TAG_HIT 의 `cgroup_id` 541334 는 파일을 쓴 세션이고 `exec_cgroup_id` 384216 은 실행한 호스트 쪽이다. action 은 BLOCK 바로 다음 줄이다.

```json
{"schema_version":1,"type":"event","session":"20261104-015543-252515","logged_at_ms":1793724943289,"event":{"kind":"TAG_HIT","pid":252634,"cgroup_id":541334,"ts_ns":3009632485587803,"exec_cgroup_id":384216,"tag_ts_ns":3009632468171554,"tag_write_count":3,"dev":265289730,"ino":526834,"filename":"/var/lib/mycontainer/containers/mycontainer-252515/upper/tmp/payload"}}
{"schema_version":1,"type":"verdict","session":"20261104-015543-252515","logged_at_ms":1793724943289,"level":"BLOCK","detector":"write_exec_boundary","reason":"세션 밖 실행, 쓴 지 0.017초: /var/lib/mycontainer/containers/mycontainer-252515/upper/tmp/payload","event":{"kind":"TAG_HIT","pid":252634,"cgroup_id":541334,"ts_ns":3009632485587803,"exec_cgroup_id":384216,"tag_ts_ns":3009632468171554,"tag_write_count":3,"dev":265289730,"ino":526834,"filename":"/var/lib/mycontainer/containers/mycontainer-252515/upper/tmp/payload"}}
{"schema_version":1,"type":"action","session":"20261104-015543-252515","logged_at_ms":1793724943289,"cgroup_id":541334,"action":"kill","result":"sent","detail":"written","errno":0,"reason":"세션 밖 실행, 쓴 지 0.017초: /var/lib/mycontainer/containers/mycontainer-252515/upper/tmp/payload"}
```

(b) 링크 위장 실행 (s08). EXEC_PATH 를 보고 exec_identity 가 [L] SUSPECT 를 낸다. 같은 실행의 TAG_HIT(쓴 세션 = 실행 세션)를 보고 write_exec_boundary 도 같은 세션 SUSPECT 를 낸다. 두 탐지기가 한 실행을 겹쳐 잡는 경우다.

```json
{"schema_version":1,"type":"event","session":"20261104-015543-252749","logged_at_ms":1793724944059,"event":{"kind":"EXEC_PATH","pid":252856,"cgroup_id":541385,"ts_ns":3009633256459409,"filename":"/tmp/bin/ls","final_name":"payload","parent_name":"tmp","grandparent_name":"/"}}
{"schema_version":1,"type":"verdict","session":"20261104-015543-252749","logged_at_ms":1793724944059,"level":"SUSPECT","detector":"exec_identity","reason":"[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 ls, 실제 payload (위치 /tmp)","event":{"kind":"EXEC_PATH","pid":252856,"cgroup_id":541385,"ts_ns":3009633256459409,"filename":"/tmp/bin/ls","final_name":"payload","parent_name":"tmp","grandparent_name":"/"}}
{"schema_version":1,"type":"verdict","session":"20261104-015543-252749","logged_at_ms":1793724944059,"level":"SUSPECT","detector":"write_exec_boundary","reason":"같은 세션 안 실행, 쓴 지 0.000초: /tmp/bin/ls","event":{"kind":"TAG_HIT","pid":252856,"cgroup_id":541385,"ts_ns":3009633256459784,"exec_cgroup_id":541385,"tag_ts_ns":3009633255474326,"tag_write_count":1,"dev":41,"ino":526851,"filename":"/tmp/bin/ls"}}
```

(c) 이미 끝난 세션의 종료 시도 (n06). 세션이 끝난 뒤 호스트가 결과물을 실행해서 BLOCK 이 나지만, cgroup 이 이미 없어 `already_gone` / `enoent` 가 된다.

```json
{"schema_version":1,"type":"action","session":"20261104-015541-252259","logged_at_ms":1793724942522,"cgroup_id":541283,"action":"kill","result":"already_gone","detail":"enoent","errno":2,"reason":"세션 밖 실행, 쓴 지 0.618초: /var/lib/mycontainer/containers/mycontainer-252259/upper/tmp/hello"}
```

(d) meta.json (s04, (a) 와 같은 세션). `exit_code` 137 은 (a) 의 종료와 맞지만, 137 만으로는 로더의 종료인지 가릴 수 없다 ("exit_code 의 의미" 절).

`command` 는 run.sh 전체가 들어가 길다.

```json
{
  "session_id": "20261104-015543-252515",
  "cgroup_id": 541334,
  "started_at": "2026-11-04T01:55:43+09:00",
  "command": "/bin/sh -c # s04_write_exec_live: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)\n#\n# 컨테이너(세션)가 파일을 쓰고 실행 권한을 준 뒤, 준비 표시(/tmp/myc_ready)를 만들고 살아 있는 채로 기다린다.\n# 이 시나리오에는 live.json 이 있으므로 러너가 준비 표시를 보고 컨테이너가 살아 있는 동안 host.sh 를 실행한다 (B안).\n# host.sh 가 쓴 파일을 세션 밖에서 실행하면 write_exec_boundary 가 BLOCK 을 내고, 로더가 살아 있는 이 세션을 cgroup.kill 로 종료한다.\n# 준비 표시는 payload 를 다 쓰고 권한을 준 뒤에 만든다 (sh 가 순서대로 실행한다). 그래야 host.sh 가 완성된 파일을 실행한다.\n# sleep 20 은 종료되기 전까지 세션을 살려 두는 역할이다. kill 이 실패하면 sleep 이 끝나 정상 종료(rc 0)하고 runtime.json 의 exit_code 137 검사가 FAIL 시킨다.\n# 20초는 러너의 준비 마감(15초)과 종료 마감(30초)의 범위 안이고 AGENT_TIMEOUT_S(60초)보다 짧다.\n# 파일 이름을 /tmp/trigger 가 아닌 /tmp/payload 로 둔 이유: 더미 탐지기 dummy_block 이 /tmp/trigger 에 BLOCK 을 내서 결과가 섞이는 것을 피하려는 것이다.\n# 실제 위험한 동작은 없다. 내용이 비어 있는 스크립트를 만들 뿐이다.\necho \"#!/bin/sh\" > /tmp/payload; chmod +x /tmp/payload; touch /tmp/myc_ready; sleep 20",
  "schema_version": 1,
  "rootfs": "/home/dev/practice/mycontainer/busybox_rootfs",
  "cgroup_path": "/sys/fs/cgroup/mycontainer-252515",
  "limits": {
    "memory": "max",
    "cpu": "max",
    "pids": "max"
  },
  "ended_at": "2026-11-04T01:55:43+09:00",
  "exit_code": 137
}
```

## 알려진 한계 (한계 목록에 반영할 것)

- 로그 쓰기가 동기식이라 디스크가 막히면 수신 루프도 멈춘다. 로더 종료 시 출력하는 `log stats`의 `slow`/`max`로 확인한다.
- 쓰기 실패는 `lost` 로 세기만 한다. 리포트에 표시하는 것은 5주차.
- cgroup_id -> 세션 대응은 캐시되며 다시 확인하지 않는다. cgroup id 가 재사용되면 잘못 기록될 수 있다.
- 세션 슬롯이 64개를 넘으면 가장 오래 안 쓴 세션의 파일을 닫는다. 이때 그 세션의 `kill_requested` 플래그도 사라져 같은 세션에서 BLOCK 이 다시 오면 종료 시도가 한 번 더 나간다. 그 cgroup 이 이미 없으면 `already_gone` 으로 기록되고, 아직 있으면 `sent` 가 다시 나갈 수 있다.
- 기록마다 `fflush` 로 커널에 넘기므로 로더가 죽어도 이미 쓴 기록은 남는다. 사라질 수 있는 것은 두 경우다: 한 줄을 쓰는 중 `fflush` 전에 로더가 죽으면 그 줄이 사라지거나 잘린 채 남고, `fsync` 를 하지 않으므로 호스트 전원이 나가거나 커널이 죽으면 아직 디스크에 쓰이지 않은 기록이 사라진다 [추론, 시험 안 함].
