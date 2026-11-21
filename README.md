# Agent Runtime Security Sandbox

AI 코딩 에이전트에게 셸 실행 권한을 줄 때, 애플리케이션 레벨 안전장치가 구조적으로 막지 못하는 우회를
에이전트 바깥, 즉 OS 커널(eBPF)에서 관측하고 판정하는 경량 런타임 샌드박스.

> **학습 목적의 데모이며 프로덕션 보안 제품이 아닙니다.**
> 새로운 취약점이나 기법을 제안하는 연구가 아니라, 이미 공개되고 패치된 사례를 학습해서 방어 시스템을 직접 구현해 보는 엔지니어링 프로젝트입니다.
> Falco, Tetragon 같은 성숙한 도구가 이미 있습니다. 직접 만드는 이유는 동작 원리를 이해하고, 이벤트를 시간 순으로 엮는 상관 탐지를 자유롭게 설계하기 위해서입니다.

## 현재 상태 (v0.1 진행 중)

| 되는 것 | 아직 안 되는 것 |
| --- | --- |
| 컨테이너(세션) 안의 `execve` 를 커널에서 관측해서 세션별 로그로 기록 | 실행 자체를 커널 안에서 거부하기 (지금은 사후 종료만, v0.3 실험 후보) |
| 탐지기를 파일 하나로 추가하는 구조 (디스패처, 판정 수집기) | 네트워크 송신 탐지 (v0.2) |
| 쓰기→실행 탐지 `write_exec_boundary`: 세션이 쓴 파일을 세션 밖에서 실행하면, 쓴 지 10분 이내는 BLOCK, 10분이 지나면 SUSPECT. 같은 세션 안 실행은 SUSPECT | |
| 실행 정체성 탐지 `exec_identity`: 메모리(memfd)에서 실행(규칙 M), `/tmp`·`/var/tmp` 바로 아래 파일을 다른 이름으로 실행(규칙 L)을 SUSPECT | |
| 시나리오를 실제로 돌려서 PASS/FAIL 을 내는 회귀 테스트 | |
| BLOCK 이면 세션 cgroup 을 `cgroup.kill` 로 종료하는 kill switch. 결과는 action 레코드의 `result` (`sent` / `already_gone` / `failed` / `skipped`, 관찰 모드에서는 `not_sent`) | |
| 평가용 관찰 모드 `--no-kill` (BLOCK 을 기록만 하고 세션은 종료하지 않음) | |
| 세션 리포트 `tools/report.sh`: 세션 폴더 하나의 SUSPECT/BLOCK 판정과 종료 대응을 사람이 읽는 목록으로 정리 (사후 검토용) | |

## 요구 사항

- 리눅스 (BTF 가 켜진 커널, `/sys/kernel/btf/vmlinux` 존재), cgroup v2, bpffs(`/sys/fs/bpf`)
- `clang`, `llvm`, `libbpf-dev`, `bpftool`, `gcc`, `jq`
- libelf 와 zlib 의 개발 파일 (로더를 `-lbpf -lelf -lz` 로 링크합니다)
- `ip`, `iptables`, `sysctl` (컨테이너 네트워크), `timeout`, `pgrep` (러너 `run_scenarios.sh`)
- root 권한 (`sudo`)
- aarch64 VM 에서만 확인했습니다. x86_64 에서는 `src/build.sh` 의 `-D__TARGET_ARCH_arm64` 를 바꿔야 할 것으로 봅니다 [추론]. 최소 커널 버전은 정하지 못했습니다 [확인 못함].
- `src/bpf/vmlinux.h` 는 없거나 비어 있으면 `build.sh` 가 현재 커널의 BTF 로 만듭니다. 이미 있으면 다시 만들지 않으므로, 커널을 올린 뒤에는 이 파일을 지우고 다시 빌드합니다.
- 세션을 실행할 때 브리지 `br0` 이 없으면 호스트 네트워크를 바꿉니다: `br0` 을 만들어 10.0.0.1/24 를 주고, `net.ipv4.ip_forward=1` 을 켜고, 10.0.0.0/24 를 외부 NIC 로 NAT(MASQUERADE)하는 iptables 규칙을 더합니다 (`br0` 이 이미 있으면 이 단계를 모두 건너뜁니다). 외부 NIC 이름은 `enp0s1` 로 고정돼 있습니다. 세션이 끝나도 br0 과 이 규칙은 되돌리지 않습니다 [코드확인].
- rootfs 기본 경로는 `/home/dev/practice/mycontainer/busybox_rootfs` 이고 `MYC_ROOTFS` 로 바꿉니다 (sudo 가 환경변수를 지우므로 `sudo env MYC_ROOTFS=경로 ./run_container.sh ...`).
  정상 시나리오(n 시리즈)의 개발 rootfs 는 `tools/make_dev_rootfs.sh` (debootstrap)로 만들고, 기본 경로는 `/home/dev/practice/mycontainer/dev_rootfs` (`MYC_DEV_ROOTFS_DIR`)입니다.
- 개발 rootfs 는 컨테이너가 매핑하는 사용자(sudo 를 부른 사용자) 소유여야 합니다. 다르면 러너가 사전 점검에서 시작을 거부합니다 (root 소유 그대로면 컨테이너 안 파일 쓰기가 EOVERFLOW 로 실패합니다). `tools/make_dev_rootfs.sh` 를 sudo 없이 실행하면 그 사용자 소유로 바꿉니다.

## 실행

```bash
cd src && ./build.sh                                  # 빌드 (eBPF 오브젝트, 로더, 단위 테스트)
sudo ./myc_loader                                     # 터미널 1: 감시자를 먼저 띄운다 (시험용 더미 탐지기는 꺼진 상태)
sudo ./run_container.sh agent-run -- /bin/sh -c '/bin/ls /'   # 터미널 2: 세션 실행
sudo ../tools/report.sh /var/lib/mycontainer/sessions/<세션 ID>   # 세션 리포트 (meta.json 이 root 전용 0600 이라 sudo. 옵션은 tools/report.sh 머리 주석)
```

로더 인자: `myc_loader [세션 루트] [--detectors=이름,이름,...] [--no-kill]` (순서 상관없음).
`--detectors` 를 생략하면 시험용이 아닌 탐지기(`exec_identity`, `write_exec_boundary`)를 모두 켭니다. 더미 탐지기는 이름으로 명시해야 켜집니다
(예: `sudo ./myc_loader --detectors=dummy_block,dummy_suspect,exec_identity,write_exec_boundary`. 러너는 이 네 탐지기를 켜고 띄웁니다).
켜진 목록과 모드는 시작할 때 `[loader] ready (... mode: kill, detectors: ...)` 줄에 나옵니다. 잘못된 인자는 시작하지 않고 종료 코드 2 로 끝납니다.

`--no-kill` 은 **평가용 관찰 모드**입니다 (예: 오탐 측정). BLOCK 이어도 세션을 종료하지 않고, `verdicts.jsonl` 에
`action=would_kill`, `result=not_sent`, `detail=observe_mode` 레코드만 남깁니다. 시작할 때 `[loader] !!! 관찰 모드` 경고가 나오고 ready 줄이 `mode: observe` 가 됩니다.
관찰 모드의 `would_kill` 은 세션당 첫 BLOCK 한 번입니다 (로더의 세션 기록 칸이 밀려났다가 다시 열리면 한 줄 더 남을 수 있습니다). 이후 BLOCK 은 판정 레코드로만 남습니다.
보호 기능이 꺼지는 모드이므로 평소 실행에 쓰지 않습니다. 러너(`run_scenarios.sh`)도 이 옵션을 쓰지 않습니다.

세션 로그는 `/var/lib/mycontainer/sessions/<세션ID>/` 의 `events.jsonl`, `verdicts.jsonl` 에 남습니다.
로그 형식은 [docs/log-schema.md](docs/log-schema.md) 를 참고하세요.

## 테스트

```bash
tools/run_unit_tests.sh          # root 가 필요 없는 시험 전부 (build.sh 뒤 C 단위 시험 10개 + 아래 셸 시험 7개)
tools/run_unit_tests.sh --skip-build   # 빌드를 건너뛰고 이미 빌드한 바이너리로
tools/test_judge.sh              # 판정 로직 (root 불필요)
tools/test_report.sh             # 리포트 생성기의 출력 문구와 입력 오류 (root 불필요)
tools/test_leak_check.sh         # 누수 점검기의 compare 판정, 가짜 스냅샷 사용 (root 불필요. snapshot, selftest 는 root 필요, VM 에서 확인)
tools/test_live_latency.sh       # B안 지연 도구의 로그 파서와 요약 (root 불필요)
tools/test_run_container.sh      # run_container.sh 가 쓰는 meta.json 의 권한·키·값, 가짜 명령 모래상자 사용 (root 불필요)
tools/test_runner.sh             # 러너 흐름, 가짜 로더 사용 (root 불필요)
tools/test_ensure_vmlinux.sh     # bpftool 로 vmlinux.h 를 만드는 단계의 성공/실패/이미 있음, 가짜 bpftool 사용 (root 불필요)
sudo ./run_scenarios.sh          # 진짜 로더와 컨테이너로 전체 시나리오
```

시나리오는 공개되어 패치된 우회 패턴을 **무해한 마커 파일 생성으로 치환**한 것입니다. 실제 위험한 페이로드는 저장소에 없습니다.

## 문서

- [설계 메모 1주차](docs/design-memo-w1.md): 구조, 인터페이스, 세션과 로그, 시나리오, 2주차로 넘기는 결정
- [설계 메모 2주차](docs/design-memo-w2.md)
- [위협 모델](docs/threat-model-w2.md): 막는 것과 보는 것, "차단"의 두 가지 의미
- [알려진 한계](docs/week1-notes.md): 해결할 것과 수용한 한계
- [로그 스키마](docs/log-schema.md): events/verdicts/meta.json 형식
- [오탐 집계표](docs/false-positive-table.md): 정상 시나리오의 SUSPECT/BLOCK 수
- [exec_identity 시나리오 정의서](docs/exec-identity-scenarios-w4.md)
- [세션 리포트 샘플](docs/sample-reports-w5.md): tools/report.sh 의 실제 출력
- [회귀 실행 기록 5주차](docs/regression-w5.md): `--repeat 10` 으로 시나리오 15개 x 10회, 150/150 통과, 약 298초

## 한계

이 프로젝트가 **하지 못하는 것**을 먼저 적습니다.

차단
- 판정이 `exec` 이후에 일어나는 사후 차단입니다. "차단"은 실행을 막는 것이 아니라, 판정 뒤 세션 cgroup 안의 프로세스를 끊어 후속 행동을 멈추는 것입니다.
- 세션 **밖**에서 일어난 실행(예: 호스트가 에이전트의 결과물을 실행)은 세션 종료로 멈추지 못합니다.
- BLOCK 은 책임 판정이 아니라 격리이며, 정상 사용에서도 납니다. 사람이 의도한 호스트 실행과 자동 실행을 구분하지 못해서, 개발자가 에이전트가 빌드한 결과물을 호스트에서 직접 실행해도 BLOCK 입니다 (시나리오 n06, 알려진 오탐).

관측과 탐지 범위
- busybox 내장 명령은 `execve` 가 없어서 커널에서 관측할 수 없습니다.
- pid 만으로 프로세스를 구분하지 않습니다. exec 는 pid 를 유지하므로 같은 pid 에서 다른 프로그램의 이벤트가 이어서 나옵니다.
- 쓰기→실행 탐지는 세션이 쓰기 모드로 연 파일만 압니다. 세션 밖에서 만든 파일, 로더 재시작 뒤, 태그가 밀려난 파일의 실행은 잡지 못합니다.
- 세션이 쓴 파일을 실행 대상이 아니라 인터프리터의 인자나 설정으로 읽히게 하면(`sh <파일>` 등) 잡지 못합니다.
- `exec_identity` 는 이름과 최종 파일이 일치하는 실행(복사, 이름 변경, 하드링크, PATH 조작, 태그가 밀려난 파일)을 보지 않습니다. 세션이 쓴 파일이면 `write_exec_boundary` 가 잡지만, 태그가 없으면 둘 다 보지 못합니다: 로더 재시작 뒤 이름이 같은 직접 실행(VM 에서 한 번 확인), 태그가 밀려난 파일과 세션 밖 파일 [추론, LRU 축출은 재현하지 못했습니다].
- 모든 exec 경로가 `security_bprm_check` 를 지나는지는 확인하지 않았습니다 (`static` 함수라 인라인될 수 있습니다). `execveat`(fd 직접 실행)는 지나는 것을 VM 에서 한 번 확인했습니다.
- TLS 로 암호화된 내용은 볼 수 없습니다.
- 컨테이너의 외부 송신은 제한하지 않습니다. `run_container.sh` 는 10.0.0.0/24 를 NAT 로 내보내는 규칙만 더하고 목적지를 제한하는 규칙은 두지 않습니다 [코드확인].

로더와 기록
- 탐지기가 세그폴트를 내면 로더 프로세스 전체가 죽습니다 (탐지기를 별도 프로세스로 분리하지 않았습니다).
- 동시에 열린 세션이 64개를 넘으면 밀려난 세션의 종료 요청 기록이 사라져, 같은 세션에 종료 요청이 한 번 더 나갈 수 있습니다.
- 로그의 문자열은 바이트 단위로 잘려 UTF-8 문자 중간에서 끊길 수 있고, 그 줄을 거부하는 JSON 파서가 있습니다 (jq 는 읽고, Python 의 json.loads 는 바이트 입력에서 거부).
- 기록은 fflush 까지만 하고 fsync 하지 않아, 호스트 전원이 나가면 마지막 기록이 사라질 수 있습니다.

실행 환경
- 에이전트는 사용자 네임스페이스 안의 root(uid 0, 전체 capability)로 실행됩니다 (호스트 기준으로는 uid 1000). 비root 전환, capability 축소, no_new_privs 같은 하드닝은 적용하지 않았습니다.
- 확인한 커널은 VM 의 7.0.0-27 (aarch64) 하나입니다. `security_file_open`, `security_bprm_check` 는 BTF 에서 `static` 함수로 표시되므로, 커널을 바꾸면 부착과 관측을 다시 확인해야 할 것으로 봅니다 [추론].

평가
- 오탐과 미탐 평가는 제한된 재현 시나리오 기준이고, 실제 워크플로우로의 일반화는 검증하지 않았습니다.
- `exec_identity` 의 오탐 0개(정상 시나리오 12개 각 한 번, n 시리즈 50세션)는 이 데모 rootfs 기준입니다. 실제 에이전트 rootfs(npm 계열 등)는 확인하지 않았습니다.
- 정상 시나리오 n02(npm install)는 개발 rootfs 에 nodejs/npm 을 설치할 수 없어 보류했습니다. 그래서 npm 계열 워크플로우는 측정하지 못했습니다.
- 점검기(누수 점검, 러너) 자체의 검증 공백(iptables, 맵 kill 경로, 작업 디렉터리, 좀비 프로세스, _unattributed)은 기록만 하고 v0.1 에서는 보강하지 않습니다.

그 밖의 한계와 각 항목의 근거는 [week1-notes.md](docs/week1-notes.md) 에 있습니다.
