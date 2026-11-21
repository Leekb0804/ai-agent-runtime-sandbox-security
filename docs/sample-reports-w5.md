# 세션 리포트 샘플 (tools/report.sh)

이 문서는 tools/report.sh 가 w5d1 VM 의 실제 세션 로그에서 만든 출력을 줄 그대로 옮긴 것이다. 단 '컨테이너 시작' 줄 하나는 w5d3 의 report.sh 가 내는 줄이라 '만든 시각'(w5d1)과 시점이 다르고, fixture 에 started 가 없어 모두 '(기록 없음)' 이다. '됨' 과 '안 됨' 문구는 이 문서의 샘플에 없고 tools/test_report.sh 에서 확인한다. 도구의 사용법은 tools/report.sh 머리 주석, 로그 형식은 docs/log-schema.md 를 본다.

- 시나리오 이름은 세션 폴더에서 알 수 없어 --scenario 로 직접 줬다.
- 출력의 '만든 시각' 은 이 샘플을 만든 시각이다 (도구를 실행할 때마다 달라진다).
- n03, n06, s00 은 tools/fixtures 에 들인 세션 폴더(real_w5_*)로 실행했다. 폴더 이름이 세션 ID 와 달라 출력에 "폴더 이름" 줄이 나온다.
- n05 는 fixture 로 들이지 않아 원본 경로로 보인다.

## 샘플 1: 의심 판정이 둘 (n03)

실제 탐지기 판정 둘이 모두 같은 세션 안 실행이다 (두 cgroup 이 같음). dummy 판정 18건은 제외되어 건수만 보인다.

```bash
tools/report.sh tools/fixtures/real_w5_n03 --scenario n03_pip_install_local
```

```
세션 리포트
- 세션 ID: 20261104-015539-251815 (출처: meta.json)
- 폴더 이름: real_w5_n03
- 시나리오: n03_pip_install_local
- 만든 시각: 2026-11-04T15:55:33+09:00
- 안내: 이 리포트는 만든 시점의 스냅샷이고, 탐지기가 낸 판정만 보여 준다.

세션 정보 (meta.json)
- 시작 시각: 2026-11-04T01:55:39+09:00
- 종료 시각: 2026-11-04T01:55:40+09:00
- exit_code: 0
- 컨테이너 시작: (기록 없음)
- rootfs: /home/dev/practice/mycontainer/dev_rootfs
- command: /bin/sh -c # n03_pip_install_local: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)\n#\n (길어서 줄임)
- 주의: exit_code 의 값만으로는 종료 원인을 가릴 수 없다. 137 이 로더의 종료 때문인지는 아래 판정 항목의 kill/sent 로만 가린다.

로더 정보
- 로더 로그를 주지 않아 lost 와 드롭은 알 수 없음

관측 (events.jsonl)
- 이벤트 36줄: EXEC 18, EXEC_PATH 16, TAG_HIT 2
- 참고: EXEC 와 EXEC_PATH 는 1:1 이 아니므로 짝짓지 않는다

판정 (verdicts.jsonl)
- dummy 판정 18건 제외 (--include-dummy 로 포함)
- 실제 탐지기 판정 2건
- [1]
  - 수준: SUSPECT (기록만)
  - 탐지기: write_exec_boundary
  - 이유: 같은 세션 안 실행, 쓴 지 0.038초: /tmp/n03venv/bin/pip
  - 이벤트 종류: TAG_HIT
  - 실행 요청 이름: /tmp/n03venv/bin/pip
  - pid: 251935
  - 파일을 쓴 세션의 cgroup: 541181
  - 실행한 쪽의 cgroup: 541181 (같음: 같은 세션 안 실행)
- [2]
  - 수준: SUSPECT (기록만)
  - 탐지기: write_exec_boundary
  - 이유: 같은 세션 안 실행, 쓴 지 0.028초: /tmp/n03venv/bin/n03tool
  - 이벤트 종류: TAG_HIT
  - 실행 요청 이름: /tmp/n03venv/bin/n03tool
  - pid: 251940
  - 파일을 쓴 세션의 cgroup: 541181
  - 실행한 쪽의 cgroup: 541181 (같음: 같은 세션 안 실행)
```

## 샘플 2: 의심 판정이 하나, 가장 짧은 예 (n05)

판정 하나. 같은 세션 안 실행이다.

```bash
tools/report.sh ~/w5_samples2/run/sessions/20261104-015541-252047 --scenario n05_script_exec
```

```
세션 리포트
- 세션 ID: 20261104-015541-252047 (출처: meta.json)
- 시나리오: n05_script_exec
- 만든 시각: 2026-11-04T15:55:33+09:00
- 안내: 이 리포트는 만든 시점의 스냅샷이고, 탐지기가 낸 판정만 보여 준다.

세션 정보 (meta.json)
- 시작 시각: 2026-11-04T01:55:41+09:00
- 종료 시각: 2026-11-04T01:55:41+09:00
- exit_code: 0
- 컨테이너 시작: (기록 없음)
- rootfs: /home/dev/practice/mycontainer/dev_rootfs
- command: /bin/sh -c # n05_script_exec: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)\n#\n# 정상 작 (길어서 줄임)
- 주의: exit_code 의 값만으로는 종료 원인을 가릴 수 없다. 137 이 로더의 종료 때문인지는 아래 판정 항목의 kill/sent 로만 가린다.

로더 정보
- 로더 로그를 주지 않아 lost 와 드롭은 알 수 없음

관측 (events.jsonl)
- 이벤트 14줄: EXEC 6, EXEC_PATH 7, TAG_HIT 1
- 참고: EXEC 와 EXEC_PATH 는 1:1 이 아니므로 짝짓지 않는다

판정 (verdicts.jsonl)
- dummy 판정 6건 제외 (--include-dummy 로 포함)
- 실제 탐지기 판정 1건
- [1]
  - 수준: SUSPECT (기록만)
  - 탐지기: write_exec_boundary
  - 이유: 같은 세션 안 실행, 쓴 지 0.001초: ./n05_task.sh
  - 이벤트 종류: TAG_HIT
  - 실행 요청 이름: ./n05_task.sh
  - pid: 252153
  - 파일을 쓴 세션의 cgroup: 541232
  - 실행한 쪽의 cgroup: 541232 (같음: 같은 세션 안 실행)
```

## 샘플 3: BLOCK 과 종료 대응 (n06, 알려진 오탐)

BLOCK 하나에 종료 대응이 붙는다. 세션이 이미 끝난 뒤 호스트가 실행해 already_gone 이다. exit_code 는 0 이다. 알려진 오탐이다 (docs/false-positive-table.md).
n06 은 n03, s04, s08 과 같은 로더 실행에서 나와 이 로그를 줄 수 있다. 값은 로더 실행 전체의 합계다.

```bash
tools/report.sh tools/fixtures/real_w5_n06 --scenario n06_host_runs_output --loader-log tools/fixtures/real_w5_loader.err
```

```
세션 리포트
- 세션 ID: 20261104-015541-252259 (출처: meta.json)
- 폴더 이름: real_w5_n06
- 시나리오: n06_host_runs_output
- 만든 시각: 2026-11-04T15:55:33+09:00
- 안내: 이 리포트는 만든 시점의 스냅샷이고, 탐지기가 낸 판정만 보여 준다.

세션 정보 (meta.json)
- 시작 시각: 2026-11-04T01:55:41+09:00
- 종료 시각: 2026-11-04T01:55:41+09:00
- exit_code: 0
- 컨테이너 시작: (기록 없음)
- rootfs: /home/dev/practice/mycontainer/dev_rootfs
- command: /bin/sh -c # n06_host_runs_output: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)\n#\n# (길어서 줄임)
- 주의: exit_code 의 값만으로는 종료 원인을 가릴 수 없다. 137 이 로더의 종료 때문인지는 아래 판정 항목의 kill/sent 로만 가린다.

로더 정보
- 이 로더 실행 전체의 합계(이 세션만의 값이 아님): lost=0, 드롭 exec=0 tag_hit=0 exec_path=0

관측 (events.jsonl)
- 이벤트 17줄: EXEC 8, EXEC_PATH 8, TAG_HIT 1
- 참고: EXEC 와 EXEC_PATH 는 1:1 이 아니므로 짝짓지 않는다

판정 (verdicts.jsonl)
- dummy 판정 8건 제외 (--include-dummy 로 포함)
- 실제 탐지기 판정 1건
- [1]
  - 수준: BLOCK (사후 종료 요청, 실행을 막지 못함)
  - 탐지기: write_exec_boundary
  - 이유: 세션 밖 실행, 쓴 지 0.618초: /var/lib/mycontainer/containers/mycontainer-252259/upper/tmp/hello
  - 이벤트 종류: TAG_HIT
  - 실행 요청 이름: /var/lib/mycontainer/containers/mycontainer-252259/upper/tmp/hello
  - pid: 252451
  - 파일을 쓴 세션의 cgroup: 541283
  - 실행한 쪽의 cgroup: 384216 (다름: 세션 밖 실행)
  - 종료 대응: kill/already_gone (enoent, errno 2) — 종료 대상이 이미 없었다 (세션이 BLOCK 전에 끝남)
```

## 샘플 4: 의심 없음 (s00)

실제 탐지기 판정이 없고 관측은 있었다.
s00 은 다른 로더 실행이라 로더 로그가 없고 lost 와 드롭은 알 수 없음으로 나온다.

```bash
tools/report.sh tools/fixtures/real_w5_s00 --scenario s00_benign
```

```
세션 리포트
- 세션 ID: 20261104-014446-228377 (출처: meta.json)
- 폴더 이름: real_w5_s00
- 시나리오: s00_benign
- 만든 시각: 2026-11-04T15:55:33+09:00
- 안내: 이 리포트는 만든 시점의 스냅샷이고, 탐지기가 낸 판정만 보여 준다.

세션 정보 (meta.json)
- 시작 시각: 2026-11-04T01:44:46+09:00
- 종료 시각: 2026-11-04T01:44:46+09:00
- exit_code: 0
- 컨테이너 시작: (기록 없음)
- rootfs: /home/dev/practice/mycontainer/busybox_rootfs
- command: /bin/sh -c # s00_benign: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)\n#\n# 무해한 명령 하나 (길어서 줄임)
- 주의: exit_code 의 값만으로는 종료 원인을 가릴 수 없다. 137 이 로더의 종료 때문인지는 아래 판정 항목의 kill/sent 로만 가린다.

로더 정보
- 로더 로그를 주지 않아 lost 와 드롭은 알 수 없음

관측 (events.jsonl)
- 이벤트 6줄: EXEC 3, EXEC_PATH 3, TAG_HIT 0
- 참고: EXEC 와 EXEC_PATH 는 1:1 이 아니므로 짝짓지 않는다

판정 (verdicts.jsonl)
- dummy 판정 3건 제외 (--include-dummy 로 포함)
- 실제 탐지기 판정 0건
- 관측은 있었다 (이벤트 6줄)
```

## 읽는 법

- BLOCK 은 사후 종료 요청이고 실행을 막지 못한다 (출력의 "BLOCK (사후 종료 요청, 실행을 막지 못함)").
- "같음/다름" 은 TAG_HIT 판정에서 파일을 쓴 세션의 cgroup(`event.cgroup_id`)과 실행한 쪽의 cgroup(`event.exec_cgroup_id`)을 비교한 것이다. 같으면 "같은 세션 안 실행", 다르면 "세션 밖 실행" 이다.
- 종료 대응의 `kill/sent` 는 `cgroup.kill` 에 써서 세션 종료를 요청했다는 뜻이고, `already_gone` 은 종료할 대상이 이미 없었다는 뜻이다 (docs/log-schema.md 의 action 절).
- dummy 판정(시험용 dummy_ 탐지기)은 기본으로 제외하고 건수만 보인다. --include-dummy 로 포함한다.
- 로더 로그를 주면 lost 와 드롭은 이 세션만의 값이 아니라 로더 실행 전체의 합계다.
- 이 리포트는 만든 시점의 스냅샷이고, 탐지기가 낸 판정만 보여 준다.
