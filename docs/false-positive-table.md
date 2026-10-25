# 정상 워크플로우 오탐 집계표 (v0.1, 3주차)

정상 작업 시나리오 5개(n01, n03, n04, n05, n06)를 러너로 돌려 탐지기의 판정을 셌다. 정상 작업이므로 기대는 BLOCK 0 이다. n06 만 알려진 오탐 BLOCK 1건을 낸다. SUSPECT 는 시나리오당 0~2건으로, 사람이 로그를 훑어볼 수 있는 분량이다. n02(npm install)는 보류했다.

이 표의 숫자는 VM 실측이다: 10-23 에 시나리오마다 따로 돌린 단독 실행(시나리오에 따라 4~5회)과 전체 실행, 10-25 의 전체 실행에서 모두 같은 값이 나왔다. 각 시나리오의 기대값은 `scenarios/<이름>/expect.json` 에 같은 값으로 고정되어 있다.

## 집계표

| 시나리오 | BLOCK | SUSPECT | 비고 |
| --- | --- | --- | --- |
| n01_compile_run | 0 | 1 | gcc 로 컴파일한 뒤 같은 세션에서 `./hello` 를 실행한 것이 SUSPECT 1. 이벤트 10줄, 판정/대응 10줄 |
| n02 (npm install) | - | - | 보류. 이 릴리스의 개발 rootfs 에서 nodejs/npm 설치가 되지 않아 제외했다 |
| n03_pip_install_local | 0 | 2 | venv 가 쓴 `bin/pip` 과 pip 이 쓴 콘솔 스크립트 `bin/n03tool` 의 실행이 각 한 번씩 SUSPECT. 이벤트 20줄, 판정/대응 20줄 |
| n04_git_clone_make | 0 | 1 | 로컬 clone 뒤 make 로 빌드한 `./hello` 의 실행이 SUSPECT 1 (git 내부 실행 파일과 make 가 부른 gcc 는 SUSPECT 를 내지 않음). 이벤트 19줄, 판정/대응 19줄 |
| n05_script_exec | 0 | 1 | 같은 세션에서 쓰고 chmod +x 한 `./n05_task.sh` 의 직접 실행이 SUSPECT 1. 이벤트 7줄, 판정/대응 7줄 |
| n06_host_runs_output | 1 | 0 | 알려진 오탐. 세션이 끝난 뒤 호스트가 컨테이너가 빌드한 결과물을 직접 실행해 write_exec_boundary 가 BLOCK (종료 시도는 already_gone 1). 컨테이너 안에서는 빌드한 파일을 실행하지 않아 SUSPECT 0. 이벤트 9줄, 판정/대응 10줄 |

BLOCK 과 SUSPECT 는 write_exec_boundary 탐지기의 판정만 센 값이다 (아래 "읽는 법").

## 읽는 법

- **SUSPECT**: write_exec_boundary 의 "같은 세션 안 실행, 쓴 지 N초 이내" 판정이다. 세션이 쓴 파일을 같은 세션이 실행했다는 기록일 뿐이고, 세션은 종료하지 않는다. 위 표의 SUSPECT 가 있는 시나리오(n01, n03, n04, n05)는 모두 종료 대응이 0건이다 (`{"type":"action"}` 기대 0).
- **BLOCK**: write_exec_boundary 의 "세션 밖 실행" 판정이다. 세션이 쓴 파일을 그 세션 밖(호스트 등)이 실행하면 낸다. BLOCK 이면 로더가 그 세션의 종료를 시도하고 결과를 대응(action) 기록으로 남긴다.
- **이벤트 줄 수, 판정/대응 줄 수**: 참고용이다. 빌드 도구마다 내부에서 실행하는 프로그램 수가 달라 시나리오끼리 비교하는 값이 아니다.
  - 러너는 시험용 더미 탐지기 dummy_suspect 도 켠다 (`run_scenarios.sh` 의 `RUNNER_DETECTORS`). dummy_suspect 는 모든 EXEC 에 SUSPECT 를 내므로 판정/대응 줄 수에는 그 판정이 섞여 있다. 그래서 표의 SUSPECT 는 detector 가 write_exec_boundary 인 것만 센 값이다 (expect.json 도 같은 방식으로 거른다).

## 알려진 오탐

- **n06_host_runs_output**: 컨테이너가 gcc 로 정상 프로그램을 빌드하고, 세션이 끝난 뒤 호스트가 그 결과물을 직접 실행한다. write_exec_boundary 는 "실행한 쪽의 cgroup 이 파일을 쓴 세션과 다르다" 는 것만 보므로 이것을 공격과 구분하지 못하고 BLOCK 을 낸다. 세션은 이미 끝나 있어 종료 시도는 already_gone 으로 기록된다.
- 탐지기가 보는 관측은 `scenarios/s04_write_exec_live`(세션이 살아 있는 동안 호스트가 에이전트가 만든 파일을 실행) 와 같다. 둘 다 "세션이 쓴 파일의 세션 밖 실행" 이고, 차이는 실행 시점에 세션이 살아 있었는지(s04 는 종료 sent, n06 은 already_gone)뿐이다. 호스트 쪽 구조는 세션 종료 뒤에 실행하는 `scenarios/s01_write_exec_cross` 와 같다 (n06 expect.json 의 description).
- 그래서 사람이 의도한 호스트 실행과 자동 실행을 구분하지 못한다. 이 동작은 한계 목록의 수용한 한계 "사람이 의도한 호스트 실행과 자동 실행을 구분하지 못함 (`write_exec_boundary`)" 에 적혀 있다 (`docs/week1-notes.md`).
- 완화 방향은 아직 정하지 않았다. 한계 목록에 후보(실행한 쪽의 맥락 확인, 검토가 끝난 산출물의 해시 허용 목록, 세션 밖 실행을 경고 수준으로 낮추기 등)만 적혀 있다.
- 이 표를 만드는 동안 탐지 규칙에 예외를 추가하지 않았다. n 시리즈 작업(5f5f2e1 이후) 동안 `src/loader/detectors/`, 디스패처, 판정 처리, 커널 프로그램은 바뀌지 않았다 (git log 로 확인).

## 한계

- 이 측정은 이 데모의 rootfs(busybox 기본 rootfs 와 개발 rootfs)와 위 시나리오들 기준이다. 일반화된 오탐률이 아니다.
- 각 시나리오는 단독 실행 4~5회와 전체 실행 2회 이상에서 같은 값이었지만, 반복 안정성을 확정한 것은 아니다.
- n02 가 빠져 npm 계열 워크플로우(패키지 설치 스크립트가 쓴 파일의 실행 등)는 측정하지 못했다. npm 은 설치 중에 쓴 스크립트를 많이 실행하므로 SUSPECT 가 이 표의 시나리오들보다 많을 수 있다 [추정].
- write_exec_boundary 는 open 시점의 쓰기 모드만 태깅하므로 rename, hardlink, mmap 쓰기, 복사 뒤 실행 등은 SUSPECT/BLOCK 으로 잡히지 않는다 (수용한 한계). 그런 경로를 쓰는 도구에서는 이 표의 숫자가 실제보다 적게 나올 수 있다 [추정].

## 다음

- 4주차에 경로 비교 탐지기가 추가되면 두 탐지기를 함께 켠 상태로 이 표를 갱신한다 (일정표 4주차 금요일).
