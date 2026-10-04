# Agent Runtime Security Sandbox

AI 코딩 에이전트에게 셸 실행 권한을 줄 때, 애플리케이션 레벨 안전장치가 구조적으로 막지 못하는 우회를
에이전트 바깥, 즉 OS 커널(eBPF)에서 관측하고 판정하는 경량 런타임 샌드박스.

> **학습 목적의 데모이며 프로덕션 보안 제품이 아닙니다.**
> 새로운 취약점이나 기법을 제안하는 연구가 아니라, 이미 공개되고 패치된 사례를 학습해서 방어 시스템을 직접 구현해 보는 엔지니어링 프로젝트입니다.
> Falco, Tetragon 같은 성숙한 도구가 이미 있습니다. 직접 만드는 이유는 동작 원리를 이해하고, 이벤트를 시간 순으로 엮는 상관 탐지를 자유롭게 설계하기 위해서입니다.

## 현재 상태 (v0.1 진행 중)

| 되는 것 | 아직 안 되는 것 |
| --- | --- |
| 컨테이너(세션) 안의 `execve` 를 커널에서 관측해서 세션별 로그로 기록 | 실제 탐지기 (지금은 동작 확인용 더미 탐지기 2개) |
| 탐지기를 파일 하나로 추가하는 구조 (디스패처, 판정 수집기) | 실제로 세션을 종료하는 kill switch (지금은 `would_kill` 만 기록) |
| 시나리오를 실제로 돌려서 PASS/FAIL 을 내는 회귀 테스트 | 쓰기→실행 탐지, 경로 비교 탐지 (2~4주차 예정) |

## 요구 사항

- 리눅스 (BTF 가 켜진 커널, `/sys/kernel/btf/vmlinux` 존재), cgroup v2, bpffs(`/sys/fs/bpf`)
- `clang`, `llvm`, `libbpf-dev`, `bpftool`, `gcc`, `jq`
- root 권한 (`sudo`)

## 실행

```bash
cd src && ./build.sh                                  # 빌드 (eBPF 오브젝트, 로더, 단위 테스트)
sudo ./myc_loader                                     # 터미널 1: 감시자를 먼저 띄운다
sudo ./run_container.sh agent-run -- /bin/sh -c '/bin/ls /'   # 터미널 2: 세션 실행
```

세션 로그는 `/var/lib/mycontainer/sessions/<세션ID>/` 의 `events.jsonl`, `verdicts.jsonl` 에 남습니다.
로그 형식은 [docs/log-schema-draft.md](docs/log-schema-draft.md) 를 참고하세요.

## 테스트

```bash
tools/test_judge.sh          # 판정 로직 (root 불필요)
tools/test_runner.sh         # 러너 흐름, 가짜 로더 사용 (root 불필요)
sudo ./run_scenarios.sh      # 진짜 로더와 컨테이너로 전체 시나리오
```

시나리오는 공개되어 패치된 우회 패턴을 **무해한 마커 파일 생성으로 치환**한 것입니다. 실제 위험한 페이로드는 저장소에 없습니다.

## 문서

- [설계 메모](docs/design-memo-w1.md): 구조, 인터페이스, 세션과 로그, 시나리오, 2주차로 넘기는 결정
- [알려진 한계](docs/week1-notes.md): 해결할 것과 수용한 한계
- [로그 스키마 초안](docs/log-schema-draft.md)

## 한계

이 프로젝트가 **하지 못하는 것**을 먼저 적습니다.

- 판정이 `exec` 이후에 일어나는 사후 차단입니다.
- busybox 내장 명령은 `execve` 가 없어서 커널에서 관측할 수 없습니다.
- 오탐과 미탐 평가는 제한된 재현 시나리오 기준이고, 실제 워크플로우로의 일반화는 검증하지 않았습니다.
- 그 밖의 한계는 [week1-notes.md](docs/week1-notes.md) 에 항목별로 있습니다.
