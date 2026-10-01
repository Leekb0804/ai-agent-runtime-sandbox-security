# v0.1 1주차 메모: 알려진 한계

1주차 관측 배관(execve → ring buffer → 로더 → JSON)의 알려진 한계.
해결하면 체크하고 해결한 커밋을 옆에 적는다.

## 로그 무결성

- [ ] **loader.c가 filename을 JSON 이스케이프하지 않음**
  - 이유: 따옴표·개행이 든 파일 이름을 exec하면 가짜 JSON 줄을 끼워 넣어 로그를 위조할 수 있다.

## 관측 범위

- [ ] **execveat은 관측하지 않음**
  - 이유: sys_enter_execve만 붙어 있어 execveat(fexecve 포함)으로 실행하면 이벤트가 남지 않는다.
- [ ] **busybox 내장 명령은 execve가 보이지 않을 수 있음**
  - 이유: 셸 내장(applet)으로 처리되면 새 프로그램을 exec하지 않으므로 커널에서 관측할 지점이 없다.
- [ ] **세션마다 부트스트랩 EXEC(/proc/self/exe)가 먼저 기록됨**
  - 이유: mycontainer_run이 phase2 진입을 위해 스스로를 re-exec하는 것이므로, 탐지기가 이를 에이전트 행동으로 오인하지 않게 걸러야 한다.

## fail-closed

- [ ] **로더가 꺼져도 pin된 map이 남아 있어 agent-run이 조용히 성공함**
  - 이유: map 등록은 성공하지만 프로그램이 detach돼 있어 관측 없이 세션이 실행된다.
- [ ] **bpf_obj_get 실패 시 아무 출력 없이 진행함** (`mycontainer_run.c`)
  - 이유: 로더를 한 번도 띄우지 않아 map이 없을 때도 감시 없이 컨테이너가 실행되고, 사용자는 이를 알 수 없다.
- [ ] **ring buffer 드롭 카운터 없음**
  - 이유: 버퍼가 가득 차면 `bpf_ringbuf_reserve` 실패로 이벤트가 버려지는데, 몇 개가 버려졌는지 남지 않아 로그 누락을 감지할 수 없다.

## 탐지기 설계 시 주의

- [ ] **pid만으로 프로세스를 구분하면 안 됨**
  - 이유: exec는 PID를 유지하므로 같은 pid에서 서로 다른 프로그램의 이벤트가 연달아 나온다.
- [ ] **ts_ns(부팅 후 경과 ns)와 meta.json의 벽시계 시각을 맞추려면 변환 필요**
  - 이유: `bpf_ktime_get_ns()`는 CLOCK_MONOTONIC 기준이라, 세션 시작/종료 시각과 바로 비교할 수 없다.
