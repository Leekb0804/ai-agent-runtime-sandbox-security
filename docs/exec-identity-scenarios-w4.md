# exec_identity 탐지기: 시나리오 정의서 (w4)

상태: **초안(구현 전, w4d1).** 일정표의 "경로 비교 탐지기(path_mismatch)" 항목을 대체한다. 이름을 exec_identity 로 바꾼 이유는, 조사로 가치가 확인된 규칙이 "경로 비교"가 아니라 "메모리에서 실행(memfd)" 이었기 때문이다. 표기: [VM확인] 사용자 VM 출력으로 확인 / [호스트 실측] VM 호스트(컨테이너 밖)에서 bpftrace 등으로 확인 / [추론] 판단 / [확인 못함] 아직 검증하지 못함. 실측은 모두 각 한 번 기준이며 반복 안정성을 확정한 것은 아니다. 코드 줄 번호는 b143281 기준이다.

## 1. 목적과 배경

- `write_exec_boundary` 는 쓰기 때 파일 inode 에 태그를 심고(`fentry/security_file_open`, `src/bpf/write_tag.h:49`), 실행 때 태그를 확인한다(`fentry/security_bprm_check`, `src/bpf/tag_hit.h:17`, 이벤트 `TAG_HIT`). 파일 이름과 위치를 보지 않고 쓰기 이력으로 잡는다.
- 구멍: 파일을 쓰지 않고 실행하는 경우(memfd)는 태그가 없다. [VM확인] 개발 rootfs 컨테이너 안에서, 로더를 띄운 채로 python3 가 `memfd_create` → `write` → `os.execve("/proc/self/fd/3", ...)` 를 실행했다. 결과는 rc=0, 세션의 `verdicts.jsonl` 은 비어 있었고 `TAG_HIT` 이벤트도 없었다. EXEC 이벤트는 세 개(`/proc/self/exe`, `/usr/bin/python3`, `/proc/self/fd/3`)였다.
- fd 를 직접 넘겨 실행하면(`os.execve(fd, ...)`, 즉 execveat) rc=0 이지만 EXEC 이벤트는 두 개뿐이고 마지막이 `/usr/bin/python3` 였다 [VM확인]. 현재 EXEC 훅(`tracepoint/syscalls/sys_enter_execve`, `src/bpf/watcher.bpf.c:78`)이 execveat 를 보지 못하기 때문이다. 한계 목록의 "execveat은 관측하지 않음"(`docs/week1-notes.md:21-22`)과 같은 현상이다.
- `security_bprm_check` 에서 보이는 값 [호스트 실측]:
  - 경로 문자열로 실행하면 `filename=/proc/self/fd/3`, 최종 dentry 이름 `memfd:x` 다.
  - fd 직접 실행이면 `filename=/dev/fd/3`, dentry 는 같은 `memfd:x` 다.
  - 즉 요청 이름은 방식마다 다르지만 최종 dentry 이름은 같다.
- 결론: EXEC 요청 이름의 접두어(`/proc/self/fd/`, `/dev/fd/`)를 보는 규칙은 fd 직접 실행과 링크로 감춘 경우를 놓치므로 채택하지 않는다. 최종 파일 이름은 `security_bprm_check` 에서 읽어야 한다.
- 링크 위장(요청 `ls` → 실제 `/tmp/payload`)은 `write_exec_boundary` 와 대부분 겹친다. `bprm->file` 은 커널이 심볼릭 링크를 다 따라간 최종 파일이고 `write_exec_boundary` 는 그 inode 로 태그를 찾는다. 그래서 세션이 쓰기 모드로 연 파일이면 이름을 바꾸든 복사하든 하드링크하든 심볼릭 링크로 감추든(심볼릭 링크는 이번에 시험하지 않아 [추론]) `write_exec_boundary` 가 잡는다.
  - [VM확인] 개발 rootfs 컨테이너 안(로더 실행 중, 세션 하나, 한 번)에서 `printf "#!/bin/sh\n:\n" > o; chmod +x o; cp o c1; ./c1; mv o m1; ./m1; ln c1 h1; ./h1` 를 돌렸다. 세 실행 모두 `TAG_HIT` 이 나왔고 `write_exec_boundary` SUSPECT 3개가 기록됐다:
    - `./c1`: 쓴 지 0.000초, ino 3938722, tag_write_count 1. `cp` 가 새 파일을 쓰기 모드로 열어 태그가 생겼다.
    - `./m1`: 쓴 지 0.009초, ino 3938721, tag_ts_ns 는 `o` 를 쓴 시각이다. `mv` 로 이름을 바꿔도 inode 가 같아 태그가 유지된다.
    - `./h1`: 쓴 지 0.003초, ino 와 tag_ts_ns 가 `c1` 과 같다. 하드링크는 같은 inode 다.
  - 이 결과는 기존 문서가 rename, hardlink, 복사 후 실행을 미탐으로 적은 것(`docs/week1-notes.md:210`, `docs/threat-model-w2.md:58`)과 다르다. 기존 서술은 "쓰기 open 없이 만들어진 파일은 태그가 없다" 는 설계상 추론에서 나온 것으로 보이며, 실제 미탐 조건은 그보다 좁다(태그가 없는 파일의 rename·링크 등) [추론].
  - 링크 위장 규칙은 선택 규칙으로 둔다(4절).

## 2. 커널에서 볼 수 있는 값과 제약

- `bpf_d_path` 는 `fentry/security_bprm_check` 에서 쓸 수 없다 [VM확인]. bpftrace 가 `helper bpf_d_path not allowed in probe` 로 로드에 실패했다. `fentry/security_file_open` 에서 `FMODE_EXEC` 조건으로는 로드된다. 하지만 그 방식은 요청 이름과 짝지어야 해서 채택하지 않는다.
- 그래서 `fentry/security_bprm_check` 에서 CO-RE 로 아래 값을 읽는다:
  - 요청 이름 `bprm->filename`
  - 최종 파일 이름 `bprm->file->f_path.dentry->d_name`
  - 부모 dentry 이름 몇 단계. 단계 수의 상한은 BPF 에서 고정한다.
- 이 값들이 컨테이너 안(overlay 위) 파일에서도 호스트 실측과 같은지는 [확인 못함] 이다. 구현 첫 단계의 확인 항목이다(8절).
- 셔뱅 스크립트에서는 `security_bprm_check` 가 두 번 불린다 [호스트 실측]. 코드 주석(`src/bpf/tag_hit.h:15`)과 같다.

| 호출 | filename | 최종 dentry | interp |
| --- | --- | --- | --- |
| 첫째 | `/tmp/shebang.XXXX` | `shebang.XXXX` | `/tmp/shebang.XXXX` |
| 둘째 | `/tmp/shebang.XXXX` | `dash` | `/bin/sh` |

  둘째 호출에서는 요청 이름과 최종 이름이 다르다. 그러나 최종 파일이 시스템 영역의 인터프리터(`/bin/sh` → `dash`)라서 임시 위치 조건(4절 규칙 L)에 걸러진다.
- 링크 해석 [호스트 실측]: `ln -s /usr/bin/sleep $t/ls; $t/ls 30 &` 를 실행하면 `/proc/<pid>/exe` 가 `/usr/lib/cargo/bin/coreutils/sleep` 였다. 이 VM 에서는 `/usr/bin/sleep` 도 링크다. 요청 이름 `ls` 와 최종 파일 이름 `sleep` 이 다르다.

## 3. 새 이벤트 EVT_EXEC_PATH (설계 제안)

- 기존 이벤트, 구조체, fixture, 더미 탐지기는 바꾸지 않고 새 종류를 추가한다. `src/bpf/event.h` 에는 enum 값, 구조체, `drop_kind` 칸(`DROP_KIND_MAX` 앞, `event.h:75-78`)이 추가된다. `event.h` 는 공용 헤더라 "탐지기·디스패처 diff 0줄" 기준에 들지 않는다.
- `security_bprm_check` 훅은 호스트 전체의 exec 마다 돈다. `tag_hit.h` 의 훅도 session_cgroups 로 거르지 않는다(`tag_hit.h:13-14`). 그래서 새 이벤트는 session_cgroups 검사를 맨 앞에 두고, 세션 밖이면 ring buffer 에 자리를 잡기 전에 return 한다(`watcher.bpf.c:85` 의 EXEC 와 같은 순서). 그렇지 않으면 호스트의 모든 실행이 이벤트가 되어 256KB 버퍼(`watcher.bpf.c:41-44`)를 채운다.
- 필드(제안):

| 필드 | 크기 | 출처 |
| --- | --- | --- |
| 헤더 `struct event_hdr` | 32B | 기존 |
| 요청 이름 | 256B (`MAX_FILENAME`) | `bprm->filename` |
| 최종 파일 이름 | 64B | `bprm->file->f_path.dentry->d_name` |
| 부모 이름 | 64B | `dentry->d_parent` |
| 조부모 이름 | 64B | `d_parent->d_parent` |

  합계는 헤더 포함 약 480B 이고, ring buffer 레코드 머리말 8B 를 더하면 256KB 버퍼에 약 500개가 들어간다 [추론]. 크기는 구현을 시작할 때 다시 정한다. 필드 순서는 `event.h:12` 의 "새 필드는 뒤에만 추가한다" 규칙을 따른다.
- 같은 실행에서 EXEC 이벤트와 EVT_EXEC_PATH 가 둘 다 나온다. execveat 로 실행하면 EVT_EXEC_PATH 만 나온다. 셔뱅 스크립트는 EVT_EXEC_PATH 가 두 번 나온다.
- 로더 쪽:
  - `src/loader/jsonl.c` 의 `kind_str`(`:37-44`)에 새 종류 이름을 더하고, 필드 출력은 `:62-73` 처럼 `len >= sizeof(...)` 검사 뒤에 한다. 이름을 더하지 않으면 `UNKNOWN` 으로 기록된다.
  - `src/loader/dispatcher.c` 의 `min_len_for_kind`(`:210-217`)는 `default: return sizeof(struct event_hdr);`(`:215`)로 빠진다. 그래서 탐지기가 길이를 직접 검사한다. `write_exec_boundary.c:26` 과 같은 관례다.

## 4. 탐지기 exec_identity

- 파일은 `src/loader/detectors/exec_identity.c`(새 파일)다.
  - 등록은 파일 안의 `__attribute__((constructor))` 로 한다. `write_exec_boundary.c:76-80` 과 같은 방식이다.
  - `src/build.sh:57-58` 이 `loader/detectors/*.c` 를 glob 으로 모아 `myc_loader` 에 링크한다.
  - 디스패처(`src/loader/dispatcher.c`, `dispatcher.h`)와 기존 탐지기 파일의 diff 는 0줄이어야 한다.
  - 이 기준 밖인 것: 시험 빌드를 위한 `build.sh` 한 단락(`:72-75` 같은 형태), `event.h`, BPF 소스, `jsonl.c`.
- **규칙 M(필수):** 최종 파일 이름이 `memfd:` 로 시작하면 SUSPECT 를 낸다.
  - 이유 문자열 예: `메모리에서 실행(memfd): 요청 /dev/fd/3, 실제 memfd:x`.
  - 이 접두어는 `memfd_create` 가 붙이므로 사용자가 바꿀 수 없다고 본다 [추론, 커널 동작 미확인].
  - 이유 문자열 버퍼는 `char reason[128]`(`src/loader/detector.h:56`)이고 한글은 글자당 3바이트다. 요청 이름이 길면 잘리므로 `write_exec_boundary.c:60` 처럼 `%.*s` 로 길이를 제한한다.
- **규칙 L(선택):** 포함 여부는 오탐 재집계 뒤에 정한다.
  - 조건: 요청 이름과 최종 파일 이름의 basename 이 다르고, **그리고** 최종 파일의 경로가 `/tmp` 또는 `/var/tmp` 안이면 SUSPECT 를 낸다. 임시 위치 목록은 탐지기 파일의 상수 배열로 둔다.
  - 조건은 반드시 AND 다. 이름만 다른 정상 실행이 많기 때문이다(아래 표).
  - 임시 위치 조건은 최종 경로 기준이어야 한다. venv 의 `/tmp/venv/bin/python` 은 요청 경로가 `/tmp` 이지만 최종 파일은 `/usr/bin/python3.x` 다.
  - 링크 위장도 세션이 쓴 파일이면 `write_exec_boundary` 가 이미 잡으므로(1절 실측은 복사·이름 변경·하드링크, 심볼릭 링크는 [추론]) 규칙 L 의 추가 가치는 더 작다. 포함 여부는 오탐 재집계 뒤에 정한다.

| 정상 실행 (요청 → 최종) | basename 불일치 | 최종 경로가 임시 위치 | 규칙 L |
| --- | --- | --- | --- |
| busybox rootfs 의 `/bin/<명령>` → `/bin/busybox` (`/bin` 링크 275개가 모두 busybox) | 예 | 아니오 | 울리지 않음 |
| dev rootfs `python3` → `python3.14` | 예 | 아니오 | 울리지 않음 |
| dev rootfs `cc` → `aarch64-linux-gnu-gcc-15`, `awk` → `mawk`, `as`, `ld` | 예 | 아니오 | 울리지 않음 |
| venv `/tmp/venv/bin/python` → `/usr/bin/python3.x` | 예 | 아니오(요청 경로만 `/tmp`) | 울리지 않음 |
| 셔뱅 둘째 호출 (스크립트 → `dash`) | 예 | 아니오 | 울리지 않음 |
| 빌드 결과물 `/tmp/hello` | 아니오 | 예 | 울리지 않음 |

- 판정 수준은 두 규칙 모두 SUSPECT 다. 지금 expect.json 12개에서 detector 필터가 없는 판정 검사는 BLOCK 개수뿐이다. 그래서 SUSPECT 만 내면 기존 시나리오는 깨지지 않는다. BLOCK 으로 올릴지는 오탐 재집계 뒤에 정한다.
- 알려진 오탐 후보: 정상 도구가 memfd 로 실행하는 경우가 있을 수 있다. n 시리즈에서 나오는지는 [확인 못함] 이다(7절).

## 5. 잡는 형태와 못 잡는 형태

| 형태 | 규칙 | 결과 | 비고 |
| --- | --- | --- | --- |
| memfd_create 후 경로 문자열(`/proc/self/fd/N`)로 실행 | M | 잡음 | `write_exec_boundary` 는 못 잡음. 컨테이너 안 실측에서 판정 0건 [VM확인] |
| memfd_create 후 fd 직접 실행(fexecve, execveat) | M | 잡음 [추론] | `dentry=memfd:x` 는 호스트 실측. 컨테이너 안은 8절 확인 항목. EXEC 훅은 이 실행을 못 봄 |
| memfd 를 링크로 감춘 실행 | M | 잡을 것으로 봄 [추론] | 8절 확인 항목 |
| 링크 위장(`/tmp/bin/ls` → `/tmp/payload`) | L | 잡음 | 세션이 쓴 파일이면 `write_exec_boundary` 도 잡음(겹침) |
| 복사, 이름 변경, 하드링크 | 없음 | exec_identity 는 못 봄(이름과 최종 파일이 일치). 겹치지 않아도 이미 잡힘 | `write_exec_boundary` 가 잡음 [VM확인] (쓴 직후 실행, 한 번). 1절 |
| PATH 조작(`PATH=/tmp:$PATH; ls` → `/tmp/ls`) | 없음 | exec_identity 는 못 봄(이름과 최종 파일이 일치). 겹치지 않아도 이미 잡힘 | `write_exec_boundary` 가 잡음 [추론, 이번 실험은 PATH 조작을 시험하지 않았다. 같은 inode 태그 메커니즘이므로] |
| 세션 밖에서 만든 파일의 rename·링크, 오래 전에 쓴 파일, LRU 로 밀린 태그, 로더 재시작 뒤 | 없음 | `write_exec_boundary` 가 못 잡을 수 있음 [추론, 실험 안 함] | exec_identity 도 이름이 일치하면 못 잡음 |
| 임시 위치 밖에 둔 링크 위장(`/usr/local/bin` 등) | 없음 | 못 잡음 | 컨테이너는 overlay 라 루트 전체가 쓰기 가능하다 [추론]. 세션이 쓴 파일이면 `write_exec_boundary` 가 잡음 |
| 명령 치환, 셸 내장 해석 | 없음 | 못 잡음(exec 가 없음) | |
| 인터프리터가 파일을 읽어 실행(`python x.py`, `sh 파일`) | 없음 | 못 잡음(최종 파일은 인터프리터) | `write_exec_boundary` 도 미탐(`docs/threat-model-w2.md` 4.3절) |
| 프로세스 안에서 코드만 로드(mmap, ctypes) | 없음 | 못 잡음(exec 가 없음) | |
| 태그가 LRU 로 밀려난 파일의 직접 실행(`write_tags` 10240개 초과, `write_tag.h:17, 39-40`) | 없음 | 못 잡음(이름이 일치) [추론, 실험 안 함] | `write_exec_boundary` 의 약점이며 이 탐지기로 메우지 못함 |

## 6. 시나리오 (제안)

| 이름 | 내용 | 기대 |
| --- | --- | --- |
| `s06_memfd_exec_path` | 컨테이너 안에서 python3 로 memfd 를 만들어 경로 문자열(`/proc/self/fd/N`)로 실행. 개발 rootfs(시나리오 폴더의 `rootfs` 파일에 `dev`) | exec_identity SUSPECT 1개, write_exec_boundary 판정 0개, BLOCK 0개, action 0개. 양성 검사로 `/usr/bin/python3` EXEC 이벤트 ≥ 1 |
| `s07_memfd_exec_fd` | fd 직접 실행(`os.execve(fd, ...)`). 개발 rootfs | s06 과 같음. EXEC 이벤트에 fd 경로가 없음을 확인하는 항목은 넣지 않는다(EXEC 이벤트 수에 기대지 않음) |
| (선택) 링크 위장 | 규칙 L 을 포함할 때만 | write_exec_boundary SUSPECT 1개와 exec_identity SUSPECT 1개가 같은 실행에서 나옴(겹침의 증거) |

- 폴더 이름 규칙은 `[sn]*/` 다(`run_scenarios.sh:257, 276, 1171`). s 시나리오는 지금 `s05` 가 마지막이고 `s99` 는 따로 쓰인다. 그래서 새 시나리오는 `s06`, `s07` 을 쓴다.
- `rootfs` 파일 규칙은 `run_scenarios.sh:28-31` 에 있다. 지금 쓸 수 있는 이름은 `dev` 하나이고, 파일이 없으면 busybox 기본 rootfs 다.
- 러너는 `run_scenarios.sh:113` `RUNNER_DETECTORS="write_exec_boundary,dummy_block,dummy_suspect"` 에 `exec_identity` 를 더해야 한다. 이 값은 로더 실행(`:1105` `--detectors="$RUNNER_DETECTORS"`)과 켜진 탐지기 확인(`:1143` `want_dets`)에 함께 쓰인다.
- expect.json 은 `"match": { "type": "verdict", "level": "SUSPECT", "detector": "exec_identity" }` 처럼 detector 로 거른다(`scenarios/n05_script_exec/expect.json` 의 write_exec_boundary 검사와 같은 형식).
- 오탐 확인은 기존 n 시리즈(n01, n03~n06)를 두 탐지기를 켠 상태로 재실행한 집계로 한다. 기존 expect.json 은 고치지 않는다.

## 7. 오탐 위험과 측정

- 규칙 M: 정상 작업에서 memfd 실행이 얼마나 자주 나오는지 모른다 [확인 못함]. n 시리즈를 exec_identity 를 켠 상태로 재실행해 규칙 M 이 울리는 시나리오를 센다.
- 규칙 L: 4절 표처럼 이름 불일치는 흔하지만 최종 경로가 시스템 영역이라 걸러진다 [추론]. 측정은 같은 재집계로 한다.
- `docs/false-positive-table.md` 의 BLOCK/SUSPECT 는 write_exec_boundary 만 센 값이다(`:18`). 재집계 때 탐지기별 열로 나눈다.

## 8. 구현 순서와 확인 항목

1. 커널 훅과 이벤트: `security_bprm_check` 에서 EVT_EXEC_PATH 를 내고 jsonl 로 출력하고 단위 시험을 붙인다. VM 확인 항목:
   - (a) 컨테이너 안(overlay)에서 dentry 를 읽으면 호스트와 같은 값이 나오는지
   - (b) 링크로 감춘 memfd 가 `memfd:x` 로 보이는지
   - (c) 세션 밖 exec 는 이벤트를 만들지 않는지
   - (d) 상한을 넘는 깊은 경로의 처리. 기본은 의심으로 보지 않는 것이다
   - (e) 드롭 카운터
2. 탐지기 exec_identity 와 단위 시험을 만들고 diff 0줄을 검증한다. 경계 케이스는 다음과 같다:
   - 길이 부족
   - memfd 접두어 경계
   - 요청 이름과 같은 이름
   - 셔뱅 둘째 호출
3. 시나리오 s06, s07 을 만들어 러너에 연결하고, 전체 회귀(기존 12개 통과)를 돌린다.
4. n 시리즈를 재집계하고 규칙 L 포함 여부를 정한다. 그다음 오탐 집계표와 설계 메모를 갱신하고 태그 v0.1-w4 를 단다.

## 9. 알려진 한계 (한계 목록 후보, 추가 전 사용자에게 질문한다)

5절의 "못 잡는 형태" 를 요약한다:

- 이름과 최종 파일이 일치하는 실행(복사, 이름 변경, 하드링크, PATH 조작, LRU 로 태그가 밀려난 파일)은 이 탐지기가 보지 않는다. 세션이 쓴 파일이면 `write_exec_boundary` 가 잡는다(복사·이름 변경·하드링크는 VM 확인). 태그가 없는 경우(LRU, 로더 재시작, 세션 밖 파일)는 둘 다 못 본다 [추론].
- 임시 위치 밖에 둔 위장(규칙 L 의 목록 밖)은 보지 않는다.
- exec 가 없는 실행(명령 치환, 셸 내장, 인터프리터가 파일을 읽어 실행, 프로세스 안 코드 로드)은 보지 않는다.

한계 목록에 넣을 문구는 이 문서에서 확정하지 않는다.

## 10. 결정 기록

| 항목 | 결정 |
| --- | --- |
| 이름 | exec_identity (일정표의 path_mismatch 를 대체) |
| 판정 수준 | 규칙 M, L 모두 SUSPECT |
| 규칙 L | 오탐 재집계 뒤에 포함 여부를 정한다 |
| 범위 | 새 이벤트 종류와 탐지기 하나. 일정이 빠듯하면 명령 치환과 PATH 조작 시나리오는 다음 주 버퍼로 옮긴다(일정표의 대비책) |
| 철회한 안 | EXEC 요청 이름 접두어만 보는 탐지기(1단계). fd 직접 실행과 링크로 감춘 경우를 놓친다 |
| 관측 | 컨테이너 안 실측: 복사·이름 변경·하드링크 후 실행을 write_exec_boundary 가 잡는다. 기존 문서의 미탐 기록과 다르다(문서 정정은 구현 4단계에서 한 번에) |

- 별도로 논의했으나 이번 범위 밖인 것: 에이전트의 쓰기 위치를 `/tmp` 로 제한하는 안(읽기 전용 루트 + 쓰기 가능 `/tmp`, 또는 Landlock).
  - 장점: 탐지 규칙의 가정을 강제로 보장한다.
  - 비용: 마운트 변경이 필요하다.
  - `/tmp` 를 tmpfs 로 두면 s01, s04, n06 이 깨질 것으로 본다. 이 세 시나리오의 `host.sh` 는 호스트에서 `"${MYC_UPPER}/tmp/payload"`(s01, s04)와 `"${MYC_UPPER}/tmp/hello"`(n06)를 직접 실행하는데, tmpfs 에 쓴 파일은 upper 에 남지 않기 때문이다 [추론. host.sh 의 경로는 코드로 확인, tmpfs 동작은 미확인].
  - README 의 향후 방향 후보다.
