#!/bin/bash
#
# run_scenarios.sh  -  시나리오 회귀 테스트 러너
#
# ===== 이 파일의 역할 =====
# scenarios/ 아래의 시나리오를 하나씩 실제로 실행하고(agent-run), 세션 로그가 기대한 모양인지 판정해서
# PASS/FAIL 을 출력한다. 한 명령으로 전체를 돌린다.
#
#     sudo ./run_scenarios.sh                # 전체
#     sudo ./run_scenarios.sh --only 's99*'  # 이름이 맞는 시나리오만 (여러 번 쓰면 합집합)
#     sudo ./run_scenarios.sh --keep         # 성공해도 로그를 보관
#     sudo ./run_scenarios.sh --repeat 100   # 한 로더 수명 안에서 N 라운드 반복하고 누수 점검 (tools/leak_check.sh)
#     sudo ./run_scenarios.sh --repeat 6 --leak-interval 1   # 중간 스냅샷 간격 (기본 10 라운드, --repeat 와 함께만)
#     (시나리오 폴더에 live.json 이 있으면 컨테이너가 살아 있는 동안 host.sh 를 실행한다. 아래 "시나리오 형식" 참고)
#
# ===== 시나리오 형식 =====
#   scenarios/<이름>/run.sh        컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 넘김)
#   scenarios/<이름>/expect.json   기대하는 세션 로그 (형식은 tools/judge.sh 의 설명 참고)
#   scenarios/<이름>/host.sh       (선택) 컨테이너가 끝난 뒤 호스트에서 실행할 스크립트. 환경변수 MYC_UPPER 로 그 컨테이너의 upperdir 를 받는다
#   scenarios/<이름>/live.json     (선택) {"ready":"tmp/myc_ready"}. 있으면 host.sh 를 컨테이너가 끝난 뒤가 아니라 살아 있는 동안 실행한다 (B안)
#                                  러너가 agent-run 을 백그라운드로 띄우고, upper/<ready> 가 새로 생기면 host.sh 를 실행한 뒤 agent-run 이 끝나기를 기다린다
#                                  ready 는 upper 기준 상대 경로 (절대 경로, .., 개행, NUL 은 거부). B안 시나리오는 host.sh 와 runtime.json 이 꼭 있어야 한다
#   scenarios/<이름>/runtime.json  (선택) 로그 밖의 기대: {"exit_code":137,"cgroup_gone":true,"map_entry_gone":true} (세 키 모두 선택)
#                                  exit_code      : agent-run 의 종료 코드. 세션 폴더 meta.json 의 exit_code 도 같아야 한다
#                                  cgroup_gone    : true 면 /sys/fs/cgroup/mycontainer-<세션 ID 끝 숫자> 가 없어야 한다 (false 는 검사 안 함)
#                                  map_entry_gone : true 면 session_cgroups 맵에 그 세션의 cgroup_id 항목이 없어야 한다 (false 는 검사 안 함)
#                                  알 수 없는 키, 잘못된 JSON, 타입 오류는 사전 점검에서 시작을 거부한다
#   scenarios/<이름>/rootfs        (선택) 쓸 rootfs 의 이름 한 단어. 지금은 dev 만 있다 (앞뒤 공백과 개행은 무시)
#                                  dev    : MYC_ROOTFS=$MYC_DEV_ROOTFS_DIR (기본 /home/dev/practice/mycontainer/dev_rootfs) 를 넘긴다
#                                  파일 없음 : MYC_ROOTFS 를 해제하고 넘긴다 (run_container.sh 의 기본 busybox rootfs)
#                                  알 수 없는 이름, 절대 경로가 아니거나 없는 dev rootfs, 소유 uid 가 SUDO_UID(없으면 id -u)와 다른 dev rootfs 는 사전 점검에서 시작을 거부한다
# 이름은 s 또는 n 으로 시작해야 한다. s 는 공격(탐지/차단 기대), n 은 정상 작업(오탐 측정).
# s00~s98 은 실제 시나리오, s99 는 더미 탐지기 검증용으로 예약해 둔다.
#
# ===== 러너가 하는 일 (순서) =====
#   1. 사전 점검(preflight): 이 도구를 믿고 돌릴 수 있는 환경인가
#   2. 임시 폴더를 만들고, 그 안을 세션 루트로 쓰는 "러너 전용 로더"를 띄운다
#      (개발 중에 쓰는 로그 폴더 /var/lib/mycontainer/sessions 를 더럽히지 않으려고 분리한다)
#   3. 시나리오마다: agent-run 실행 -> 세션 ID 추출 -> 로더가 다 쓸 때까지 대기 -> 판정
#   4. 로더를 종료하고 인프라 검증 (로그 유실 0, ring buffer 드롭 0, _unattributed 비어 있음)
#   5. 요약 출력. 하나라도 실패하면 종료 코드 1
#
# ===== 종료 코드 =====
#   0 : 전부 통과      1 : 하나 이상 실패      2 : 환경 문제로 시작하지 못함 (사전 점검 실패 등)
#   "시작하지 못함(2)"과 "테스트가 실패함(1)"을 구분해서, 환경이 틀려서 아무것도 안 돌았는데
#   성공처럼 보이는 일을 막는다.
#
# ===== 알려진 한계 =====
#   - 세션 ID 는 agent-run 이 출력하는 "[*] 세션 시작: <ID> ..." 줄에서 뽑는다. 그 출력 형식이 바뀌면 깨진다.
#   - ring buffer 드롭 수는 로더가 종료할 때 실행 전체 합계로 한 번만 출력한다. 러너는 로더를 끈 뒤 그 줄을 읽어 확인하므로,
#     드롭이 있으면 실행 전체를 실패로 보지만 어느 시나리오에서 버려졌는지는 알 수 없다.
#   - 시나리오 하나당 컨테이너를 새로 띄우므로 느리다 (개수가 적은 v0.1 에서는 문제없다).

# ===== 이 파일을 읽는 방법 (쉘 문법이 낯설다면) =====
# 위에서 아래로 "함수 정의 -> 메인" 순서이다. 함수(preflight, run_one 등)는 정의만 해 두고, 실제 실행은 맨 아래
# "메인" 구역의 preflight 호출부터 시작한다. 처음에는 메인 구역을 먼저 읽고, 필요할 때 함수로 내려가면 쉽다.
# 기본 문법(set -u, ${1:-}, [[ ]], $( ), 배열, $?, 종료 코드)은 tools/judge.sh 의 주석에 설명해 두었다.
# 여기서 새로 나오는 문법(함수, case, while, 백그라운드 실행, trap 등)은 해당 줄에 설명을 달았다.
# set -u : 값이 정해지지 않은 변수를 쓰면 오류로 즉시 멈춘다 (오타 방지).
set -u

# 이 스크립트가 있는 폴더의 절대 경로를 구한다. 어디서 실행하든 같은 결과가 나오게 하는 관용구이다.
#   $0             : 이 스크립트의 경로 (실행한 그대로. 예: ./run_scenarios.sh)
#   dirname "$0"   : 거기서 파일 이름을 뗀 폴더 부분 (예: .)
#   cd 폴더 && pwd : 그 폴더로 이동한 뒤 현재 위치를 절대 경로로 출력한다.
#   $( ) 안에서 한 이동은 바깥 스크립트의 위치를 바꾸지 않는다. $( ) 가 겹쳐 있으면 안쪽부터 실행된다.
HERE="$(cd "$(dirname "$0")" && pwd)"
# ${MYC_SRC_DIR:-$HERE/src} : 환경변수 MYC_SRC_DIR 가 있으면 그 값, 없으면 $HERE/src.
# 평소에는 진짜 src 를 쓰고, 테스트에서만 가짜 구현이 있는 폴더로 바꿔 끼운다.
# 환경변수 지정법: 명령 앞에 변수=값 을 붙이면 그 명령에만 전달된다 (예: MYC_SRC_DIR=tools/mock ./run_scenarios.sh).
SRC_DIR="${MYC_SRC_DIR:-$HERE/src}"        # 테스트에서만 가짜 구현으로 바꿔 끼운다 (tools/test_runner.sh)
# 시나리오 폴더. 평소에는 저장소의 scenarios/ 이고 테스트에서만 MYC_SCEN_DIR 로 바꿔 끼운다 (tools/test_runner.sh). 이름은 s 또는 n 으로 시작해야 한다. s 는 공격(탐지/차단 기대), n 은 정상 작업(오탐 측정).
SCEN_DIR="${MYC_SCEN_DIR:-$HERE/scenarios}"
# 컨테이너 폴더(upperdir 이 있는 곳)의 부모. host.sh 스텝이 컨테이너가 쓴 파일을 찾을 때 쓴다. 테스트에서는 MYC_CONTAINERS_ROOT 로 바꾼다.
CONTAINERS_ROOT="${MYC_CONTAINERS_ROOT:-/var/lib/mycontainer/containers}"
# rootfs 파일이 dev 인 시나리오에 넘길 개발 rootfs 위치. 기본값은 tools/make_dev_rootfs.sh 의 DEFAULT_DIR 과 같다
# sudo 는 환경변수를 지우므로 바꾸려면 sudo env MYC_DEV_ROOTFS_DIR=경로 ./run_scenarios.sh 형태로 넘긴다
DEV_ROOTFS_DIR="${MYC_DEV_ROOTFS_DIR:-/home/dev/practice/mycontainer/dev_rootfs}"
JUDGE="$HERE/tools/judge.sh"
# 런타임 검사가 "읽기만" 하는 경로와 도구. 테스트에서만 바꿔 끼운다 (tools/test_runner.sh).
# 러너는 이 경로를 확인만 하고 쓰지 않는다. 세션을 종료하는 경로(src/loader/kill.c 의 /sys/fs/cgroup)는 컴파일 시점에 고정이라 영향이 없다.
CHECK_CGROUP_ROOT="${MYC_CHECK_CGROUP_ROOT:-/sys/fs/cgroup}"              # cgroup_gone 이 확인할 cgroup 루트
BPFTOOL="${MYC_BPFTOOL:-bpftool}"                                         # map_entry_gone 이 쓸 bpftool (이름이면 PATH 에서 찾는다)
SESSION_CGROUPS_PIN="${MYC_SESSION_CGROUPS_PIN:-/sys/fs/bpf/session_cgroups}"  # 로더가 pin 하는 감시 맵 (watcher.bpf.c 의 LIBBPF_PIN_BY_NAME)

# 대문자 이름의 변수는 "상수처럼 쓰는 설정값"이라는 관례이다 (쉘 문법상 특별한 것은 아니다). 필요하면 값만 조정한다.
SETTLE_MS=500           # 이벤트 로그가 이 시간 동안 늘지 않으면 로더가 다 썼다고 본다
SETTLE_MAX_S=10         # 이 시간을 넘겨도 안정되지 않으면 실패로 본다
AGENT_TIMEOUT_S=60      # 시나리오 하나가 이 시간을 넘기면 중단한다
# 로더가 준비되기를 기다리는 최대 시간(초). 기본 10. MYC_READY_TIMEOUT_S 는 테스트(tools/test_runner.sh)에서 줄이는 용도로만 쓴다.
# 양의 정수(1~9999)가 아니면 사전 점검이 시작을 거부한다 (아래 대기 반복문이 이 값을 계산에 쓰기 때문이다)
READY_TIMEOUT_S="${MYC_READY_TIMEOUT_S:-10}"
RUNTIME_TRIES=20        # cgroup 소멸, 맵 항목 소멸을 확인하는 최대 횟수 (0.1초 간격, 최대 약 2초)
# B안(live.json) 시나리오의 마감(초). 모두 AGENT_TIMEOUT_S 보다 훨씬 짧아야 한다 (60초 timeout 경로는 에이전트와 격리 자원을 남긴다)
LIVE_READY_TIMEOUT_S=15   # agent-run 을 띄운 뒤 준비 표시(upper/<ready>)가 새로 생기기를 기다리는 최대 시간
LIVE_EXIT_TIMEOUT_S=30    # host.sh 뒤에 agent-run 이 끝나기를 기다리는 최대 시간 (BLOCK 으로 세션이 종료되어야 한다)
LIVE_HOST_TIMEOUT_S=10    # B안의 host.sh 하나가 쓸 수 있는 최대 시간
LIVE_CLEANUP_WAIT_S=10    # 정리 때 cgroup.kill 을 쓴 뒤 agent-run 이 끝나기를 기다리는 최대 시간
# B안 정리(live_cleanup)가 쓰는 상태. EXIT 트랩도 이 값을 보고 정리한다. 비어 있으면 정리할 것이 없다
LIVE_PID=""               # 백그라운드 agent-run 의 pid
LIVE_SID=""               # agent.out 에서 뽑은 세션 ID (cgroup 이름의 숫자를 얻는다)
LIVE_CGID=""              # agent.out 에서 뽑은 cgroup_id (cgroup.kill 을 쓰기 전에 inode 와 비교한다)
LIVE_RC=""                # B안에서 받은 agent-run 의 종료 코드
LIVE_LEFT=""              # 정리 뒤에도 agent-run 이 남았으면 그 세션 cgroup 이름 (mycontainer-N, 모르면 "<모름>")
# 러너 전용 로더에 켤 탐지기. 로더는 --detectors 가 없으면 더미(시험용)를 켜지 않는다.
# s99, s03 은 dummy_block 의 BLOCK 에, s99 의 마지막 기대는 dummy_suspect 의 판정에 의존한다. 이 목록은 여기서만 정한다.
# 일부러 알파벳순이 아닌 순서로 둔다. ready 줄은 로더가 정렬해서 내므로, 아래 want_dets 의 정렬이 빠지면 테스트(ld1)가 잡는다.
RUNNER_DETECTORS="write_exec_boundary,dummy_block,dummy_suspect"

# 옵션 상태. KEEP=1 이면 성공해도 로그를 보관한다. FILTERS 는 --only 로 받은 이름 패턴들이다 (여러 번 받으면 합집합).
KEEP=0
FILTERS=()
# --repeat 로 받은 라운드 수. 비어 있으면 반복 모드가 아니다 (기존 동작과 같다)
REPEAT=""
# --leak-interval 로 받은 중간 스냅샷 간격(라운드). 비어 있으면 기본 10 을 쓴다. --repeat 와 함께만 쓸 수 있다
LEAK_INTERVAL=""
# 반복 모드의 누수 점검기. 테스트에서만 MYC_LEAK_CHECK 로 가짜를 끼운다 (tools/mock/leak_check.sh)
LEAK_CHECK="${MYC_LEAK_CHECK:-$HERE/tools/leak_check.sh}"

# 함수 정의 : 이름() { ... }. 부를 때는 이름만 쓴다 (usage). 함수 안의 $1 은 함수에 준 인자이다 (스크립트의 $1 과 별개).
# sed -n '3,15p' "$0" : 이 파일 자신의 3~15번째 줄만 출력한다. 즉 --help 는 위쪽 주석의 사용법 부분을 그대로 보여 준다.
#    그래서 파일 맨 위 15줄은 줄 수를 바꾸면 안 된다 (줄이 추가되면 --help 출력이 어긋난다).
# 두 번째 sed 는 각 줄 앞의 "# " 를 지운다.
usage() {
    sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# 옵션 처리 반복문.
#   $#                : 아직 처리하지 않은 인자의 개수. -gt 는 "보다 크다" 이므로 인자가 남아 있는 동안 반복한다.
#   case "$1" in 패턴) 명령 ;; ... esac
#                     : $1 이 어느 패턴과 맞는지 보고 그 명령을 실행하는 다중 분기 (긴 if-elif 와 비슷).
#                       ;; 가 한 분기의 끝, esac 이 case 의 끝이다.
#   shift             : 인자를 하나 앞으로 당긴다 ($2 가 $1 이 된다). shift 2 는 둘을 버린다 (옵션과 그 값).
#   *)                : 위 어느 것과도 맞지 않는 나머지 전부.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        # --only 패턴 : 옵션 바로 뒤의 값($2)을 FILTERS 에 더하고, 옵션과 값 둘을 소비한다 (shift 2).
        #               여러 번 쓰면 패턴들의 합집합을 고른다. 값이 없으면 거부한다 (shift 2 가 실패해 같은 자리를 도는 것도 막는다)
        --only)
            # 값이 없으면 사용 오류로 끝낸다
            [[ $# -ge 2 ]] || { echo "--only 에는 패턴 값이 필요하다 (--help 참고)" >&2; exit 2; }
            # 패턴을 목록에 더한다
            FILTERS+=("$2")
            # 옵션과 값을 소비한다
            shift 2 ;;
        # --repeat N : 선택한 시나리오를 한 로더 수명 안에서 N 라운드 돈다. 값 검사는 사전 점검에서 한다
        --repeat)
            # 값이 없으면 사용 오류로 끝낸다
            [[ $# -ge 2 ]] || { echo "--repeat 에는 라운드 수가 필요하다 (--help 참고)" >&2; exit 2; }
            # 라운드 수를 받는다
            REPEAT="$2"
            # 옵션과 값을 소비한다
            shift 2 ;;
        # --leak-interval K : 반복 모드에서 K 라운드마다 중간 스냅샷을 찍는다. 값 검사는 사전 점검에서 한다
        --leak-interval)
            # 값이 없으면 사용 오류로 끝낸다
            [[ $# -ge 2 ]] || { echo "--leak-interval 에는 라운드 수가 필요하다 (--help 참고)" >&2; exit 2; }
            # 간격을 받는다
            LEAK_INTERVAL="$2"
            # 옵션과 값을 소비한다
            shift 2 ;;
        -h|--help) usage ;;
        *) echo "알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
done

# 시나리오 이름이 실행 대상인지 본다. --only 가 없으면 전부, 있으면 패턴 중 하나라도 맞으면 대상이다 (사전 점검과 메인이 같이 쓴다)
selected() {
    # 시나리오 이름과 반복 변수
    local n="$1" p
    # 패턴이 하나도 없으면 전부 대상이다
    ((${#FILTERS[@]} == 0)) && return 0
    # 패턴을 하나씩 본다
    for p in "${FILTERS[@]}"; do
        # 패턴은 셸 글롭이라 따옴표 없이 비교한다
        # shellcheck disable=SC2053
        [[ "$n" == $p ]] && return 0
    done
    # 맞는 패턴이 없다
    return 1
}

# ---------------------------------------------------------------------------------------------
# 1. 사전 점검
# ---------------------------------------------------------------------------------------------
# 환경이 틀린 채로 돌리면 "모든 시나리오가 실패"하거나, 더 나쁘게는 "아무것도 관측하지 못했는데 통과"한다.
# 그래서 시작 전에 전제 조건을 전부 확인하고, 하나라도 틀리면 이유를 모두 보여 주고 멈춘다 (fail-closed).
# MYC_RUNNER_TEST=1 은 테스트 전용이다. 가짜 로더로 러너의 흐름만 검증할 때 root, bpffs, cgroup v2 확인을 건너뛴다.
preflight() {
    # local : 이 함수 안에서만 쓰는 변수 (함수 밖의 같은 이름 변수를 건드리지 않는다).
    # errs=() 는 오류 메시지를 모아 둘 빈 배열이다.
    local errs=()

    # ${MYC_RUNNER_TEST:-0} : 환경변수가 없으면 0. != 1 이므로 "테스트 모드가 아니면" (평소 실행이면) 이라는 뜻이다.
    # 문자열 비교는 [[ ]] 안에서 == 와 != 로 한다.
    if [[ "${MYC_RUNNER_TEST:-0}" != 1 ]]; then
        # $EUID : 지금 실행 중인 사용자의 번호 (root 는 0).
        # [[ 조건 ]] || 명령 : 조건이 거짓일 때만 뒤의 명령을 실행한다. 즉 root 가 아니면 오류 목록에 메시지를 추가한다.
        [[ $EUID -eq 0 ]] || errs+=("root 권한이 필요하다: sudo ./run_scenarios.sh")
        # 로더가 이미 떠 있으면 같은 map 에 프로그램이 두 번 붙어서 이벤트가 두 번씩 기록된다
        # pgrep -x 이름 : 그 이름의 프로세스가 실행 중이면 성공한다. -x 는 이름 전체가 정확히 같을 때만 (일부만 같은 것은 제외).
        if pgrep -x myc_loader >/dev/null 2>&1; then
            errs+=("이미 myc_loader 가 실행 중이다. 끄고 다시 실행하라 (pgrep -a myc_loader)")
        fi
        # mount | grep -q '...' : mount 가 출력한 마운트 목록을 grep 에 넘겨(|), bpffs 가 마운트된 줄이 있는지 본다.
        # 없으면 (A || B 는 A 가 실패하면 B 실행) 오류 목록에 추가한다.
        mount | grep -q ' /sys/fs/bpf type bpf' || errs+=("/sys/fs/bpf 에 bpffs 가 마운트되어 있지 않다")
        # stat -fc %T 경로 : 그 경로가 놓인 파일시스템의 종류 이름을 출력한다. cgroup v2 이면 cgroup2fs 이다.
        # $( ) 로 그 출력을 받아서 문자열 비교한다.
        [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]] || errs+=("cgroup v2 가 아니다 (/sys/fs/cgroup)")
    fi

    # 아래 몇 줄은 모두 "[[ 확인 ]] || errs+=(메시지)" 꼴이다. 확인이 실패하면 메시지를 목록에 모아 둔다.
    # 하나가 틀려도 바로 멈추지 않고 전부 확인한 뒤 한꺼번에 보여 주려는 것이다.
    #   -x 파일 : 실행할 수 있는 파일인가.    -d 경로 : 폴더인가.
    command -v jq >/dev/null 2>&1 || errs+=("jq 가 필요하다: sudo apt install jq")
    # =~ 정규식: 0 으로 시작하지 않는 1~4자리 숫자만 받는다. 0, 빈 값, 글자, 음수, 너무 큰 값은 거부한다
    [[ "$READY_TIMEOUT_S" =~ ^[1-9][0-9]{0,3}$ ]] || errs+=("MYC_READY_TIMEOUT_S 는 1~9999 의 양의 정수여야 한다: '$READY_TIMEOUT_S'")
    [[ -x "$JUDGE" ]] || errs+=("판정기가 없거나 실행할 수 없다: $JUDGE")
    [[ -x "$SRC_DIR/myc_loader" ]] || errs+=("$SRC_DIR/myc_loader 가 없다. 먼저 빌드하라: cd src && ./build.sh")
    [[ -x "$SRC_DIR/run_container.sh" ]] || errs+=("$SRC_DIR/run_container.sh 가 없거나 실행할 수 없다")
    # run_container.sh 가 세션 루트를 바꿀 수 있어야 한다. 그렇지 않으면 로그가 러너가 보는 곳이 아닌
    # 기본 위치로 가서 모든 시나리오가 "이벤트 없음"으로 실패한다.
    # grep -q '문자열' 파일 : 파일 안에 그 문자열이 있으면 성공한다. 앞의 ! 로 뒤집어서 "없으면" 이 된다.
    # 2>/dev/null 은 파일이 없을 때 나오는 오류 메시지를 버린다.
    if ! grep -q 'MYC_SESSIONS_ROOT' "$SRC_DIR/run_container.sh" 2>/dev/null; then
        errs+=("run_container.sh 가 MYC_SESSIONS_ROOT 를 지원하지 않는다 (SESSIONS_ROOT=\"\${MYC_SESSIONS_ROOT:-/var/lib/mycontainer/sessions}\" 로 바꿔야 한다)")
    fi
    [[ -d "$SCEN_DIR" ]] || errs+=("시나리오 폴더가 없다: $SCEN_DIR")
    # 반복 모드: 라운드 수는 1~9999 의 양의 정수여야 하고, 누수 점검기를 실행할 수 있어야 한다
    if [[ -n "$REPEAT" ]]; then
        # 0, 글자, 음수, 너무 큰 값은 거부한다
        [[ "$REPEAT" =~ ^[1-9][0-9]{0,3}$ ]] || errs+=("--repeat 는 1~9999 의 양의 정수여야 한다: '$REPEAT'")
        # 점검기가 없으면 반복은 돌아도 누수를 판정할 수 없으므로 시작하지 않는다
        [[ -x "$LEAK_CHECK" ]] || errs+=("누수 점검기가 없거나 실행할 수 없다: $LEAK_CHECK")
    fi
    # 스냅샷 간격: 반복 모드에서만 쓸 수 있고, --repeat 와 같은 범위(1~9999)여야 한다
    if [[ -n "$LEAK_INTERVAL" ]]; then
        # 반복 모드가 아니면 쓸 곳이 없으므로 거부한다 (조용히 무시하지 않는다)
        [[ -n "$REPEAT" ]] || errs+=("--leak-interval 은 --repeat 와 함께만 쓸 수 있다")
        # 0, 글자, 음수, 너무 큰 값은 거부한다
        [[ "$LEAK_INTERVAL" =~ ^[1-9][0-9]{0,3}$ ]] || errs+=("--leak-interval 은 1~9999 의 양의 정수여야 한다: '$LEAK_INTERVAL'")
    fi
    # --only 패턴마다 맞는 시나리오가 하나 이상 있어야 한다 (오타로 일부가 조용히 빠지는 것을 막는다)
    local p hit sd
    for p in "${FILTERS[@]}"; do
        # 이 패턴에 맞는 폴더를 찾았는지 표시
        hit=0
        # 메인과 같은 규칙([sn]*/ 폴더)으로 찾는다
        for sd in "$SCEN_DIR"/[sn]*/; do
            # 폴더가 아니면 건너뛴다
            [[ -d "$sd" ]] || continue
            # 끝의 / 를 떼고 이름만 본다. 패턴은 글롭이라 따옴표 없이 비교한다
            # shellcheck disable=SC2053
            if [[ "$(basename "${sd%/}")" == $p ]]; then hit=1; break; fi
        done
        # 하나도 없으면 그 패턴을 적어 거부한다
        [[ $hit -eq 1 ]] || errs+=("--only 패턴에 맞는 시나리오가 없다: '$p'")
    done

    # 실행할 시나리오의 runtime.json 을 미리 검증한다. 오타로 검사가 조용히 빠지는 것을 막으려는 것이다.
    # need_bpftool : map_entry_gone 을 쓰는 시나리오가 하나라도 있으면 1
    local d rt need_bpftool=0
    # rf : rootfs 파일에서 읽은 이름. dev_users : rootfs 가 dev 인 시나리오 이름들 (하나라도 있으면 dev rootfs 를 검사한다)
    local rf dev_users=()
    # any_live : live.json 시나리오가 하나라도 있으면 1 (마감 합을 검사한다)
    local any_live=0
    # 메인의 실행 반복문과 같은 규칙([sn]*/ 폴더, --only 패턴)으로 실행 대상만 고른다
    for d in "$SCEN_DIR"/[sn]*/; do
        # 폴더가 아니면 건너뛴다 (맞는 것이 없으면 패턴이 글자 그대로 남는다)
        [[ -d "$d" ]] || continue
        # 끝의 / 를 뗀 경로
        d="${d%/}"
        # --only 패턴과 맞지 않으면 실행하지 않을 시나리오이므로 건너뛴다
        selected "$(basename "$d")" || continue
        # rootfs 파일이 있으면 이름을 읽어 확인한다 (runtime.json 검사보다 먼저 한다. 아래의 continue 에 건너뛰지 않게)
        if [[ -f "$d/rootfs" ]]; then
            # 앞뒤 공백과 개행을 자른 이름
            rf="$(read_rootfs_name "$d/rootfs")"
            # 아는 이름이면 dev 를 쓰는 시나리오로 기억하고, 아니면 시나리오 이름과 값을 적어 거부한다
            if [[ "$rf" == dev ]]; then
                # 아래에서 dev rootfs 를 한 번만 검사하려고 모은다
                dev_users+=("$(basename "$d")")
            else
                # 무엇이 틀렸고 무엇을 쓸 수 있는지 알린다
                errs+=("rootfs 파일의 이름을 알 수 없다: $(basename "$d") 의 rootfs = '$rf' (쓸 수 있는 이름: dev)")
            fi
        fi
        # live.json 이 있으면 B안 시나리오이다. 형식과 짝 파일을 확인한다 (runtime.json 검사보다 먼저 한다. 아래의 continue 에 건너뛰지 않게)
        if [[ -f "$d/live.json" ]]; then
            # 마감 합 검사를 한 번만 하려고 표시한다
            any_live=1
            # 객체이고 키가 ready 하나뿐이며, 값은 비어 있지 않은 문자열이고 / 로 시작하지 않으며 .., 개행, NUL 을 포함하지 않아야 한다
            if ! jq -e '
                  type == "object"
                  and (keys == ["ready"])
                  and (.ready | type == "string")
                  and (.ready | length > 0)
                  and (.ready | startswith("/") | not)
                  and (.ready | contains("..") | not)
                  and (.ready | contains("\n") | not)
                  and (.ready | contains("\u0000") | not)
                ' "$d/live.json" >/dev/null 2>&1; then
                # 무엇이 허용되는지 함께 알려 준다
                errs+=("live.json 형식 오류: $d/live.json (허용: {\"ready\":\"<upper 기준 상대 경로>\"}, 절대 경로, .., 개행, NUL 은 안 됨)")
            fi
            # B안은 컨테이너가 살아 있는 동안 host.sh 를 실행하는 것이므로 host.sh 가 없으면 할 일이 없다
            [[ -f "$d/host.sh" ]] || errs+=("live.json 이 있는데 host.sh 가 없다: $d")
            # 살아 있는 세션이 종료되었는지는 exit_code 로 확인해야 하므로 runtime.json 이 꼭 있어야 한다
            [[ -f "$d/runtime.json" ]] || errs+=("live.json 이 있는데 runtime.json 이 없다: $d (세션 종료를 exit_code 로 확인해야 한다)")
        fi
        # runtime.json 이 있는 시나리오만 검증한다
        rt="$d/runtime.json"
        [[ -f "$rt" ]] || continue
        # 객체이고, 아는 키만 있고, exit_code 는 0~255 정수, 나머지 둘은 true/false 여야 한다
        if ! jq -e '
              type == "object"
              and ((keys - ["exit_code", "cgroup_gone", "map_entry_gone"]) | length == 0)
              and ((has("exit_code") | not) or (.exit_code | type == "number" and . == floor and . >= 0 and . <= 255))
              and ((has("cgroup_gone") | not) or (.cgroup_gone | type == "boolean"))
              and ((has("map_entry_gone") | not) or (.map_entry_gone | type == "boolean"))
            ' "$rt" >/dev/null 2>&1; then
            # 무엇이 허용되는지 함께 알려 준다
            errs+=("runtime.json 형식 오류: $rt (허용 키: exit_code 0~255 정수, cgroup_gone/map_entry_gone true|false)")
            continue
        fi
        # map_entry_gone 이 true 이면 bpftool 이 필요하다
        if jq -e '.map_entry_gone == true' "$rt" >/dev/null 2>&1; then need_bpftool=1; fi
    done
    # B안 시나리오가 있으면 두 마감의 합이 agent-run 의 timeout 보다 작아야 한다 (넘으면 60초 timeout 경로로 빠진다)
    if [[ $any_live -eq 1 ]] && ((LIVE_READY_TIMEOUT_S + LIVE_EXIT_TIMEOUT_S >= AGENT_TIMEOUT_S)); then
        # 세 값을 함께 알린다
        errs+=("B안 마감의 합(${LIVE_READY_TIMEOUT_S}+${LIVE_EXIT_TIMEOUT_S}초)이 AGENT_TIMEOUT_S(${AGENT_TIMEOUT_S}초) 이상이다")
    fi
    # 맵 검사가 필요한데 bpftool 이 없으면 검사를 건너뛰지 않고 시작을 거부한다 (SKIP 은 가짜 통과가 된다)
    if [[ $need_bpftool -eq 1 ]] && ! command -v "$BPFTOOL" >/dev/null 2>&1; then
        errs+=("map_entry_gone 검사에 bpftool 이 필요하다: $BPFTOOL (sudo apt install bpftool 또는 linux-tools)")
    fi
    # dev rootfs 를 쓰는 시나리오가 있을 때만 그 폴더를 검사한다 (없으면 이 검사를 하지 않는다)
    if ((${#dev_users[@]} > 0)); then
        # 컨테이너가 사용자 네임스페이스에서 uid 0 으로 매핑하는 호스트 uid (run_container.sh 와 mycontainer_run 의 SUDO_UID, 없으면 getuid)
        local want_uid="${SUDO_UID:-$(id -u)}" got_uid
        # 어느 시나리오 때문에 검사하는지 메시지에 붙인다
        local who="rootfs=dev 시나리오: ${dev_users[*]}"
        # 절대 경로가 아니면 거부한다. run_container.sh 는 src 로 이동한 뒤 절대 경로만 받으므로, 상대 경로는 여기서 통과해도 시나리오마다 실패한다
        if [[ "$DEV_ROOTFS_DIR" != /* ]]; then
            # 값과 이유를 적는다. 존재와 소유자 검사는 하지 않는다 (상대 경로는 러너 위치 기준이라 run_container.sh 가 볼 폴더와 다를 수 있다)
            errs+=("MYC_DEV_ROOTFS_DIR 는 절대 경로여야 한다: '$DEV_ROOTFS_DIR' ($who)")
        # 폴더가 없으면 만드는 방법과 함께 거부한다
        elif [[ ! -d "$DEV_ROOTFS_DIR" ]]; then
            errs+=("dev rootfs 가 없다: $DEV_ROOTFS_DIR ($who). 일반 사용자로(sudo 없이) tools/make_dev_rootfs.sh 를 실행해 만든다 (다른 위치는 MYC_DEV_ROOTFS_DIR)")
        else
            # 소유 uid. -L 은 링크면 가리키는 폴더를 본다 (overlay 의 lowerdir 로 쓰이는 것이 그 폴더이다)
            got_uid="$(stat -L -c %u -- "$DEV_ROOTFS_DIR" 2>/dev/null)"
            # 다르면 overlay copy-up 이 EOVERFLOW 로 실패해 컨테이너 안에서 파일을 쓸 수 없다. 이유와 고치는 방법과 함께 거부한다
            if [[ "$got_uid" != "$want_uid" ]]; then
                errs+=("dev rootfs 의 소유 uid 가 '$got_uid' 인데 컨테이너가 매핑하는 uid 는 $want_uid 이다: $DEV_ROOTFS_DIR ($who). 이대로면 컨테이너 안 파일 쓰기가 EOVERFLOW 로 실패한다. 일반 사용자로(sudo 없이) tools/make_dev_rootfs.sh 를 실행해 다시 만든다 (그 스크립트는 대상이 이미 있으면 멈추므로 MYC_DEV_ROOTFS_DIR 로 새 위치를 주고 러너에도 같은 값을 준다)")
            fi
        fi
    fi

    # (( 수식 )) : 숫자 비교. ${#errs[@]} 는 배열 원소 개수이므로 "오류가 하나라도 모였으면" 이다.
    if ((${#errs[@]} > 0)); then
        echo "[preflight] 시작할 수 없다. 아래를 해결하라:" >&2
        # printf '형식' 값들 : 값마다 형식을 한 번씩 적용해서 출력한다. 배열 "${errs[@]}" 를 주면 오류 하나당 한 줄이 된다.
        printf '  - %s\n' "${errs[@]}" >&2
        exit 2
    fi
}

# ---------------------------------------------------------------------------------------------
# 도우미
# ---------------------------------------------------------------------------------------------

# 시나리오의 rootfs 파일에서 이름을 읽어 앞뒤 공백과 개행을 잘라 출력한다 (사전 점검과 run_one 이 같은 규칙을 쓰게 한다)
read_rootfs_name() {
    # $(<파일) 은 파일 내용이고 끝의 개행은 빠진다
    local v
    v="$(<"$1")"
    # 앞쪽 공백류를 자른다: ${v%%[![:space:]]*} 는 첫 공백 아닌 글자 앞까지(앞쪽 공백), 그것을 앞에서 뗀다
    v="${v#"${v%%[![:space:]]*}"}"
    # 뒤쪽 공백류를 자른다: ${v##*[![:space:]]} 는 마지막 공백 아닌 글자 뒤(뒤쪽 공백), 그것을 뒤에서 뗀다
    v="${v%"${v##*[![:space:]]}"}"
    # 자른 이름을 출력한다 (가운데 공백은 남으므로 "d ev" 는 알 수 없는 이름이 된다)
    printf '%s' "$v"
}

# 파일의 줄 수. 파일이 없으면 0.
count_lines() {
    # wc -l <파일 : 줄 수를 센다 (<로 파일 내용을 입력으로 주면 출력에 파일 이름이 붙지 않는다).
    # tr -d ' ' : 공백을 지운다 (시스템에 따라 숫자 앞에 공백이 붙는다).
    # if/then/else/fi 를 한 줄에 쓸 때는 명령 사이를 ; 로 구분한다.
    if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi
}

# 로더가 다 쓸 때까지 기다린다.
# 왜 필요한가: agent-run 이 끝나도 로더는 ring buffer 에서 이벤트를 비동기로 꺼내 쓴다 (최대 100ms 간격).
# 끝나자마자 로그를 읽으면 아직 덜 쓰인 로그를 보고 잘못 실패한다.
# 방법: events.jsonl 의 줄 수가 SETTLE_MS 동안 변하지 않으면 다 썼다고 본다.
# 이벤트가 하나도 없으면(줄 수 0) 안정된 것으로 치지 않고 시간 초과로 실패한다 (아무것도 못 본 것이므로).
wait_settled() {
    # 한 줄에 지역 변수를 여럿 선언하고 값을 넣을 수 있다.
    #   last=-1 : 아직 한 번도 줄 수를 세지 않았다는 표시.   stable : 줄 수가 변하지 않은 채 지난 시간(ms).
    #   waited  : 지금까지 기다린 총 시간(ms).               step_ms : 한 번에 쉬는 시간(ms).
    local f="$1" last=-1 now stable=0 waited=0 step_ms=100
    # (( )) 안에서는 변수 앞에 $ 없이 쓸 수 있고 계산도 된다. 최대 SETTLE_MAX_S 초 동안 반복한다.
    while ((waited < SETTLE_MAX_S * 1000)); do
        now="$(count_lines "$f")"
        # 흐름: 0.1초마다 줄 수를 센다. 지난번과 같고(==) 0 보다 크면(-gt 0) 안정된 시간을 늘리고,
        # 달라졌거나 아직 0 줄이면 안정 시간을 0 으로 되돌린다.
        if [[ "$now" == "$last" && "$now" -gt 0 ]]; then
            # $(( 수식 )) : 계산 결과를 값으로 돌려준다 (여기서는 stable 에 step_ms 를 더한다).
            stable=$((stable + step_ms))
            # 안정된 시간이 기준(SETTLE_MS) 이상이면 && 뒤의 return 0 이 실행되어 함수가 성공(0)으로 끝난다.
            # return 은 함수에서 쓰는 exit 이다 (스크립트 전체가 아니라 이 함수만 끝낸다).
            ((stable >= SETTLE_MS)) && return 0
        else
            stable=0
            last="$now"
        fi
        # sleep 0.1 : 0.1 초 쉬었다가 다음 반복으로 간다.
        sleep 0.1
        waited=$((waited + step_ms))
    done
    # 시간 안에 안정되지 않았다. 실패(1)를 돌려준다. 부른 쪽에서 if ! wait_settled ...; then 으로 받는다.
    return 1
}

# ---------------------------------------------------------------------------------------------
# 런타임 검사: 로그 밖의 기대(runtime.json)를 확인한다. 모두 맞으면 0, 하나라도 어긋나면 1.
# 어긋난 항목마다 한 줄씩 이유를 출력한다 (부르는 쪽이 들여써서 보여 준다).
#   $1 runtime.json  $2 세션 ID  $3 agent-run 종료 코드  $4 cgroup_id (agent-run 출력에서 뽑은 값)  $5 세션 폴더
# ---------------------------------------------------------------------------------------------
run_runtime_checks() {
    # 인자를 이름 있는 변수로 받는다. fails 는 어긋난 항목 수이다
    local rt="$1" sid="$2" rc="$3" cgid="$4" sdir="$5" fails=0
    # 이 함수 안에서 쓰는 변수들
    local want meta_rc cgdir hex key b i dump n gone

    # cgroup_id 를 못 뽑았으면 어떤 검사도 대상을 확정할 수 없으므로 바로 실패한다
    if [[ ! "$cgid" =~ ^[0-9]+$ ]]; then
        # 무엇을 기대했는지 알려 준다
        echo "[런타임] cgroup_id 를 얻지 못함 (agent-run 출력의 \"cgroup_id=<숫자>\" 가 없거나 숫자가 아님: '$cgid')"
        # 실패로 돌아간다
        return 1
    fi

    # (a) 종료 코드. jq -r '.exit_code // empty' 는 키가 없으면 빈 문자열이다
    want="$(jq -r '.exit_code // empty' "$rt")"
    # 키가 있을 때만 검사한다
    if [[ -n "$want" ]]; then
        # agent-run 의 종료 코드가 기대와 같아야 한다
        if [[ "$rc" != "$want" ]]; then
            # 137 을 기대했으면 "죽지 않았다"는 뜻을 함께 알린다 (124 는 timeout 이 끊은 것)
            if [[ "$want" == 137 ]]; then
                echo "[런타임] 종료 코드 $rc: 137 아님 (세션이 cgroup.kill 로 종료되지 않았다. 124 는 timeout 이 끊은 것)"
            else
                echo "[런타임] 종료 코드 불일치: 기대 $want, 실제 $rc"
            fi
            # 어긋난 항목 수를 센다
            fails=$((fails + 1))
        fi
        # meta.json 의 exit_code 가 같은 값으로 기록되었는지 교차 확인한다 (run_container.sh 가 끝날 때 쓴다)
        # 파일이 없거나 JSON 이 깨지면 빈 문자열, 키가 없으면 "missing"
        meta_rc="$(jq -r 'if has("exit_code") then (.exit_code | tostring) else "missing" end' "$sdir/meta.json" 2>/dev/null)"
        # 세 경우를 나눠서 알린다
        if [[ -z "$meta_rc" ]]; then
            echo "[런타임] meta.json 을 읽지 못함: $sdir/meta.json"
            fails=$((fails + 1))
        elif [[ "$meta_rc" == missing ]]; then
            echo "[런타임] meta.json 에 exit_code 가 없음: $sdir/meta.json"
            fails=$((fails + 1))
        elif [[ "$meta_rc" != "$rc" ]]; then
            echo "[런타임] meta.json 의 exit_code $meta_rc 가 agent-run 종료 코드 $rc 와 다름"
            fails=$((fails + 1))
        fi
    fi

    # (b) cgroup 디렉토리 소멸. run_container.sh 가 끝날 때 rmdir 하므로 보통은 이미 없다. 짧게 다시 확인한다
    if jq -e '.cgroup_gone == true' "$rt" >/dev/null 2>&1; then
        # 세션 ID 끝의 숫자가 cgroup 이름의 숫자이다 (run_container.sh 의 mycontainer-$$)
        cgdir="$CHECK_CGROUP_ROOT/mycontainer-${sid##*-}"
        # 없어졌는지 표시
        gone=0
        # 0.1초 간격으로 최대 RUNTIME_TRIES 번 확인한다
        for ((i = 0; i < RUNTIME_TRIES; i++)); do
            # -e 는 있으면 참, -L 은 링크면 참. 둘 다 아니면 없어진 것이다
            if [[ ! -e "$cgdir" && ! -L "$cgdir" ]]; then gone=1; break; fi
            # 다음 확인까지 쉰다
            sleep 0.1
        done
        # 끝까지 남아 있으면 실패
        if [[ $gone -ne 1 ]]; then
            echo "[런타임] cgroup 디렉토리가 남아 있음: $cgdir (${RUNTIME_TRIES}회 확인)"
            fails=$((fails + 1))
        fi
    fi

    # (c) session_cgroups 맵 항목 소멸. 로더가 kill(sent) 직후 지운다
    if jq -e '.map_entry_gone == true' "$rt" >/dev/null 2>&1; then
        # cgroup_id 를 16자리 16진수로 (8바이트)
        hex="$(printf '%016x' "$cgid")"
        # 리틀엔디안: 낮은 바이트부터. bpftool -j 의 key 배열과 같은 모양 ["0x85","0x1b",...] 으로 만든다
        key="["
        # 마지막 두 자리(가장 낮은 바이트)부터 앞으로 간다
        for ((b = 7; b >= 0; b--)); do
            # ${hex:시작:길이} 로 두 글자씩 자른다
            key+="\"0x${hex:$((b * 2)):2}\""
            # 마지막 원소가 아니면 쉼표
            ((b > 0)) && key+=","
        done
        # 배열을 닫는다
        key+="]"
        # 없어졌는지 표시
        gone=0
        # 0.1초 간격으로 최대 RUNTIME_TRIES 번 확인한다
        for ((i = 0; i < RUNTIME_TRIES; i++)); do
            # 맵 전체를 JSON 으로 받는다. stderr 는 실패했을 때 보여 주려고 파일에 따로 둔다
            dump="$("$BPFTOOL" -j map dump pinned "$SESSION_CGROUPS_PIN" 2>"$WORK/bpftool.err")"
            # bpftool 자체가 실패하면 다시 시도하지 않고 바로 실패한다 (건너뛰면 가짜 통과가 된다)
            if [[ $? -ne 0 ]]; then
                echo "[런타임] bpftool 실패: $BPFTOOL -j map dump pinned $SESSION_CGROUPS_PIN ($(head -c 200 "$WORK/bpftool.err"))"
                fails=$((fails + 1))
                # 아래의 "끝까지 남음" 메시지를 내지 않도록 표시한다
                gone=2
                break
            fi
            # 원본 키 바이트(.key)로만 비교한다 ("formatted" 는 쓰지 않는다). 배열이 아니면 jq 가 실패한다
            n="$(jq --argjson k "$key" 'if type == "array" then [.[] | select(.key == $k)] | length else error("배열 아님") end' <<<"$dump" 2>/dev/null)"
            # JSON 이 깨졌으면 다시 시도하지 않고 바로 실패한다
            if [[ ! "$n" =~ ^[0-9]+$ ]]; then
                echo "[런타임] bpftool 출력을 해석하지 못함 (JSON 배열이 아님): $(head -c 200 <<<"$dump")"
                fails=$((fails + 1))
                gone=2
                break
            fi
            # 항목이 없으면 통과 (빈 맵 [] 도 여기로 온다)
            if [[ "$n" -eq 0 ]]; then gone=1; break; fi
            # 아직 있으면 잠깐 쉬고 다시 확인한다
            sleep 0.1
        done
        # 끝까지 남아 있으면 실패
        if [[ $gone -eq 0 ]]; then
            echo "[런타임] session_cgroups 에 cgroup_id $cgid 항목이 남아 있음 (key $key, ${RUNTIME_TRIES}회 확인)"
            fails=$((fails + 1))
        fi
    fi

    # 어긋난 항목이 하나라도 있으면 실패
    ((fails == 0))
}

# 판정기의 탭 구분 출력을 사람이 읽기 좋게 바꿔 들여쓴다. 실패한 검사만 보여 준다 (--keep 이면 전부).
print_judge() {
    # 이 함수는 표준 입력으로 판정기의 출력을 받는다 (부르는 쪽의 <<<"$out" 참고).
    # 함수의 인자 $1 은 "전부 보여 줄지(1) 실패만 보여 줄지(0)" 이다.
    local show_all="$1" st num match want note
    # while read ...; do ... done : 입력을 한 줄씩 읽어서 반복한다.
    # IFS=$'\t'  : 한 줄을 나누는 구분 문자를 탭으로 지정한다 (판정기가 탭으로 구분해서 출력했다).
    # read -r 변수들 : 한 줄을 구분 문자로 잘라 변수에 차례로 넣는다. -r 은 백슬래시를 특별하게 다루지 않는다.
    #                  마지막 변수(note)가 나머지를 전부 받는다.
    while IFS=$'\t' read -r st num match want note; do
        # FAIL* : 패턴 비교 (* 는 아무 글자). [[ ]] 안에서 == 오른쪽을 따옴표 없이 쓰면 패턴으로 비교한다.
        if [[ "$st" == FAIL* || "$show_all" == 1 ]]; then
            # %s 는 문자열 자리이고 %-4s 는 왼쪽 정렬 4칸이다. 뒤의 값들이 순서대로 들어간다.
            printf '        %-4s %s  %s\n' "$st" "$num" "$want"
            printf '             match: %s\n' "$match"
            # -n 문자열 : 비어 있지 않으면 참 (-z 의 반대). 메모(note)가 있을 때만 "의도"를 출력한다.
            [[ -n "$note" ]] && printf '             의도 : %s\n' "$note"
        fi
    done
}

# ---------------------------------------------------------------------------------------------
# B안(live.json) 정리. 백그라운드 agent-run 이 남아 있으면 세션 cgroup 에 cgroup.kill 을 써서 끝내고 기다린다.
# 세션 cgroup 의 inode 가 agent.out 에서 뽑은 cgroup_id 와 같을 때만 쓴다 (이름이 같은 다른 cgroup 을 죽이지 않으려는 것이다).
# 무엇을 했는지 한 줄씩 출력한다 (부르는 쪽의 FAIL 메시지 아래에 붙는다). B안 FAIL 경로와 EXIT 트랩이 부른다.
# ---------------------------------------------------------------------------------------------
live_cleanup() {
    # cg 는 세션 cgroup 경로, ino 는 그 inode, waited 는 기다린 횟수(0.1초 단위)
    local cg ino waited=0 lrc
    # 정리할 agent-run 이 없으면 할 일이 없다
    [[ -n "$LIVE_PID" ]] || return 0
    # 세션 ID 와 cgroup_id 를 둘 다 알아야 대상 cgroup 을 확정할 수 있다
    if [[ -n "$LIVE_SID" && "$LIVE_CGID" =~ ^[0-9]+$ ]]; then
        # cgroup_gone 검사와 같은 경로 규칙 (세션 ID 끝 숫자 = run_container.sh 의 $$)
        cg="$CHECK_CGROUP_ROOT/mycontainer-${LIVE_SID##*-}"
        # 디렉터리가 있을 때만 쓴다 (없으면 이미 끝난 것이다)
        if [[ -d "$cg" && ! -L "$cg" ]]; then
            # 지금 그 이름의 cgroup inode (cgroup v2 에서는 inode 가 cgroup_id 이다)
            ino="$(stat -c %i -- "$cg" 2>/dev/null)"
            # 같은 cgroup 일 때만 cgroup.kill 에 1 을 쓴다
            if [[ "$ino" == "$LIVE_CGID" ]]; then
                # 쓰기 결과를 알린다 (실패해도 아래에서 기다리기는 한다)
                if echo 1 >"$cg/cgroup.kill" 2>/dev/null; then
                    echo "[정리] cgroup.kill 에 1 을 씀: $cg"
                else
                    echo "[정리] cgroup.kill 쓰기 실패: $cg"
                fi
            else
                # 다른 cgroup 이므로 쓰지 않는다
                echo "[정리] cgroup inode '$ino' 가 cgroup_id $LIVE_CGID 와 달라 cgroup.kill 을 쓰지 않음: $cg"
            fi
        else
            # 이미 없으면 쓸 곳이 없다
            echo "[정리] 세션 cgroup 이 없음: $cg"
        fi
    else
        # 세션 시작 줄을 아직 못 봤다
        echo "[정리] 세션 ID 나 cgroup_id 를 몰라 cgroup.kill 을 쓰지 않음"
    fi
    # agent-run 이 끝나기를 최대 LIVE_CLEANUP_WAIT_S 초 기다린다 (run_container.sh 의 정상 정리가 돌 시간)
    while kill -0 "$LIVE_PID" 2>/dev/null && ((waited < LIVE_CLEANUP_WAIT_S * 10)); do
        # 0.1초 쉬고 다시 본다
        sleep 0.1
        # 기다린 횟수를 센다
        waited=$((waited + 1))
    done
    # 끝까지 살아 있으면 남았다고 알린다 (러너가 더 할 수 있는 일은 없다)
    if kill -0 "$LIVE_PID" 2>/dev/null; then
        echo "[정리] agent-run(pid $LIVE_PID) 이 ${LIVE_CLEANUP_WAIT_S}초 뒤에도 남아 있음. 세션 cgroup, netns, 맵 항목을 손으로 정리해야 한다"
        # 부르는 쪽이 러너를 멈추도록 남은 세션 cgroup 이름을 남긴다 (세션 ID 를 모르면 이름도 모른다)
        if [[ -n "$LIVE_SID" ]]; then LIVE_LEFT="mycontainer-${LIVE_SID##*-}"; else LIVE_LEFT="<모름>"; fi
    else
        # 끝났으면 종료 코드를 받아 알린다
        wait "$LIVE_PID" 2>/dev/null
        # wait 의 결과가 agent-run 의 종료 코드이다
        lrc=$?
        echo "[정리] agent-run 종료 (종료 코드 $lrc)"
    fi
    # 다시 정리하지 않도록 상태를 비운다
    LIVE_PID=""
    LIVE_SID=""
    LIVE_CGID=""
}

# B안 FAIL 경로의 정리. 정리 결과를 들여써서 붙이고, 정리 뒤에도 agent-run 이 남았으면 러너 전체를 멈춘다 (종료 코드 2).
# 남은 세션이 다음 시나리오와 누수 점검을 오염시키므로 다음 시나리오, 인프라 검증, 누수 비교를 하지 않는다. 로그 보관은 EXIT 트랩이 한다.
#   $1 시나리오 이름 (정리 출력 파일 이름에 쓴다)
live_fail_cleanup() {
    # 정리는 이 셸에서 해야 상태를 비우고 wait 할 수 있으므로 파이프 대신 파일을 거쳐 들여써서 붙인다
    LIVE_LEFT=""
    live_cleanup >"$WORK/$1.cleanup.out"
    sed 's/^/        /' "$WORK/$1.cleanup.out"
    # 남은 것이 없으면 그 시나리오만 FAIL 하고 다음으로 간다
    [[ -z "$LIVE_LEFT" ]] && return 0
    # 남은 세션과 손으로 정리하는 방법을 알린다
    echo "[runner] 세션 cgroup $LIVE_LEFT 이(가) 정리 뒤에도 남아 러너를 멈춘다 (다음 시나리오, 인프라 검증, 누수 비교를 하지 않는다)"
    echo "[runner] 손으로 정리: echo 1 | sudo tee $CHECK_CGROUP_ROOT/$LIVE_LEFT/cgroup.kill  (그 뒤 남은 netns, 맵 항목은 timeout 확인 절차처럼 하나씩 정리)"
    # 실패로 표시해 작업 폴더를 남기고 종료 코드 2 로 끝낸다 (로더 정리는 EXIT 트랩이 한다)
    ANY_FAIL=1
    exit 2
}

# ---------------------------------------------------------------------------------------------
# B안(live.json) 실행. agent-run 을 백그라운드로 띄우고, 준비 표시가 오면 host.sh 를 실행한 뒤 agent-run 이 끝나기를 기다린다.
#   $1 시나리오 폴더  $2 이름  $3 스크립트  $4 ready (upper 기준 상대 경로)
# 성공하면 0 이고 LIVE_RC 에 agent-run 의 종료 코드를 남긴다. 실패하면 FAIL 메시지를 내고 정리한 뒤 1 이다.
# rootfs_env 는 부르는 쪽(run_one)의 지역 변수를 그대로 쓴다 (bash 함수는 부른 함수의 지역 변수를 본다).
# ---------------------------------------------------------------------------------------------
run_live() {
    # 인자를 이름 있는 변수로 받는다
    local dir="$1" name="$2" script="$3" ready="$4"
    # ref 는 준비 표시가 "새것"인지 비교할 기준 파일, out 은 agent-run 출력, cdir 은 컨테이너 폴더
    local ref="$WORK/$name.live_ref" out="$WORK/$name.agent.out" sid cgid cdir="" i ok=0 hrc lrc
    # 기준 파일을 agent-run 보다 먼저 만든다. 이전 실행이 남긴 준비 표시(PID 재사용)는 이것보다 오래되어 무시된다
    : >"$ref"
    # 지난 B안 실행의 상태를 비운다
    LIVE_RC=""
    LIVE_SID=""
    LIVE_CGID=""
    # A안과 같은 줄을 백그라운드(&)로 실행한다 (timeout, 환경변수, 출력 파일 그대로)
    ( cd "$SRC_DIR" && MYC_SESSIONS_ROOT="$SESS_ROOT" \
        timeout "$AGENT_TIMEOUT_S" env "${rootfs_env[@]}" ./run_container.sh agent-run -- /bin/sh -c "$script" ) \
        >"$out" 2>&1 &
    # 방금 띄운 하위 셸의 pid. EXIT 트랩도 이 값을 보고 정리한다
    LIVE_PID=$!
    # 준비 표시를 0.1초마다 최대 LIVE_READY_TIMEOUT_S 초 기다린다
    for ((i = 0; i < LIVE_READY_TIMEOUT_S * 10; i++)); do
        # 세션 시작 줄을 아직 못 봤으면 찾아 본다
        if [[ -z "$cdir" ]]; then
            # run_one 과 같은 sed 로 세션 ID 와 cgroup_id 를 뽑는다
            sid="$(sed -n 's/^\[\*\] 세션 시작: \([^ ]*\) (cgroup_id=.*/\1/p' "$out" | head -1)"
            # 같은 줄의 cgroup_id
            cgid="$(sed -n 's/^\[\*\] 세션 시작: [^ ]* (cgroup_id=\([^)]*\)).*/\1/p' "$out" | head -1)"
            # 둘 다 형식이 맞을 때만 컨테이너 폴더를 확정한다 (이상한 글자가 든 세션 ID 는 경로로 쓰지 않는다)
            if [[ "$sid" =~ ^[A-Za-z0-9._-]+$ && "$cgid" =~ ^[0-9]+$ ]]; then
                # 정리가 쓸 수 있게 알려 둔다
                LIVE_SID="$sid"
                LIVE_CGID="$cgid"
                # A안과 같은 규칙의 컨테이너 폴더
                cdir="$CONTAINERS_ROOT/mycontainer-${sid##*-}"
            fi
        fi
        # 준비 표시가 기준 파일보다 새것이면 준비된 것이다 (-nt: 수정 시각이 더 나중)
        if [[ -n "$cdir" && "$cdir/upper/$ready" -nt "$ref" ]]; then ok=1; break; fi
        # 준비되기 전에 agent-run 이 끝났으면 기다릴 이유가 없다
        if ! kill -0 "$LIVE_PID" 2>/dev/null; then
            # 종료 코드를 받는다
            wait "$LIVE_PID" 2>/dev/null
            # wait 의 결과가 agent-run 의 종료 코드이다
            lrc=$?
            # 이미 끝났으므로 정리할 것이 없다
            LIVE_PID=""
            echo "[FAIL] $name"
            echo "        준비 전에 agent-run 이 끝남 (종료 코드 $lrc)"
            echo "        출력: $out"
            return 1
        fi
        # 0.1초 쉬고 다시 본다
        sleep 0.1
    done
    # 마감 안에 준비 표시가 오지 않았으면 실패하고 정리한다
    if [[ $ok -ne 1 ]]; then
        echo "[FAIL] $name"
        echo "        준비 표시가 오지 않음 (${LIVE_READY_TIMEOUT_S}초, ${cdir:-<컨테이너 폴더 모름>}/upper/$ready)"
        echo "        출력: $out"
        # 정리하고, 그래도 세션이 남았으면 러너를 멈춘다 (live_fail_cleanup)
        live_fail_cleanup "$name"
        return 1
    fi
    # 준비되었다. 컨테이너가 살아 있는 동안 host.sh 를 실행한다 (짧은 timeout, 출력은 시나리오별 파일)
    MYC_UPPER="$cdir/upper" timeout "$LIVE_HOST_TIMEOUT_S" /bin/bash "$dir/host.sh" >"$WORK/$name.host.out" 2>&1
    # 종료 코드를 바로 저장한다
    hrc=$?
    # host.sh 가 실패하면 판정까지 가지 않고 정리한다
    if [[ $hrc -ne 0 ]]; then
        echo "[FAIL] $name"
        echo "        호스트 스텝(host.sh)이 실패했다. 종료 코드 $hrc"
        echo "        출력: $WORK/$name.host.out"
        # 정리하고, 그래도 세션이 남았으면 러너를 멈춘다 (live_fail_cleanup)
        live_fail_cleanup "$name"
        return 1
    fi
    # BLOCK 으로 세션이 종료되어 agent-run 이 끝나기를 최대 LIVE_EXIT_TIMEOUT_S 초 기다린다
    for ((i = 0; i < LIVE_EXIT_TIMEOUT_S * 10; i++)); do
        # 끝났으면 빠져나간다
        kill -0 "$LIVE_PID" 2>/dev/null || break
        # 0.1초 쉬고 다시 본다
        sleep 0.1
    done
    # 아직 살아 있으면 실패하고 정리한다
    if kill -0 "$LIVE_PID" 2>/dev/null; then
        echo "[FAIL] $name"
        echo "        BLOCK 뒤에도 세션이 끝나지 않음 (${LIVE_EXIT_TIMEOUT_S}초)"
        echo "        출력: $out"
        # 정리하고, 그래도 세션이 남았으면 러너를 멈춘다 (live_fail_cleanup)
        live_fail_cleanup "$name"
        return 1
    fi
    # 끝났다. 종료 코드를 받는다
    wait "$LIVE_PID" 2>/dev/null
    # 부르는 쪽이 읽는다
    LIVE_RC=$?
    # 정리할 것이 없다
    LIVE_PID=""
    LIVE_SID=""
    LIVE_CGID=""
    return 0
}

# ---------------------------------------------------------------------------------------------
# 시나리오 하나 실행. 통과하면 0, 실패하면 1.
# ---------------------------------------------------------------------------------------------
run_one() {
    # 반환값: 통과하면 return 0, 실패하면 return 1. 부르는 쪽이 if run_one ...; then 으로 성공/실패를 받는다.
    local dir="$1" name script sid sdir events verdicts rc jr cgid rt_out rtr
    # basename 경로 : 경로의 마지막 부분 (폴더 이름). 예: .../scenarios/s99_dummy_block -> s99_dummy_block
    name="$(basename "$dir")"

    # 시나리오 폴더에 run.sh 와 expect.json 이 둘 다 있어야 한다. || 는 "또는" 이므로 하나라도 없으면 형식 오류이다.
    if [[ ! -f "$dir/run.sh" || ! -f "$dir/expect.json" ]]; then
        echo "[FAIL] $name"
        echo "        시나리오 형식 오류: run.sh 와 expect.json 이 모두 있어야 한다"
        return 1
    fi
    # $(cat 파일) : 파일 내용을 문자열로 읽어서 script 변수에 담는다. 이 문자열을 컨테이너 안에서 sh -c 로 실행한다.
    script="$(cat "$dir/run.sh")"
    # live.json 이 있으면 B안(live=1)이고 ready 경로를 읽는다 (형식은 사전 점검이 확인했다)
    local live=0 ready=""
    if [[ -f "$dir/live.json" ]]; then
        # B안 표시
        live=1
        # 준비 표시의 upper 기준 경로
        ready="$(jq -r '.ready' "$dir/live.json")"
    fi

    # 이 시나리오에만 줄 rootfs 환경. env 의 인자로 쓴다 (기본: MYC_ROOTFS 를 해제해 부른 셸의 값이 새어 들어가지 않게 한다)
    local rootfs_env=(-u MYC_ROOTFS) rf=""
    # rootfs 파일이 있으면 이름을 읽는다 (사전 점검과 같은 규칙)
    [[ -f "$dir/rootfs" ]] && rf="$(read_rootfs_name "$dir/rootfs")"
    # 이름에 따라 고른다
    case "$rf" in
        # 파일이 없으면 해제한 채로 둔다 (run_container.sh 의 기본 busybox rootfs)
        "") ;;
        # dev 이면 개발 rootfs 경로를 넘긴다
        dev) rootfs_env=(MYC_ROOTFS="$DEV_ROOTFS_DIR") ;;
        # 사전 점검이 거부했어야 하는 이름이다. 기본 rootfs 로 조용히 돌리지 않고 이 시나리오를 실패로 한다 (fail-closed)
        *)
            echo "[FAIL] $name"
            echo "        rootfs 이름을 처리하지 못함: '$rf' (사전 점검을 지나친 값)"
            return 1
            ;;
    esac

    # agent-run 실행. run_container.sh 는 ./mycontainer_run 을 상대 경로로 부르므로 src 로 이동해서 실행한다.
    # MYC_SESSIONS_ROOT 로 세션 로그가 러너 전용 폴더로 가게 한다.
    # timeout 은 시나리오가 멈춰 버리는 경우를 막는다.
    # 이 명령의 문법:
    #   ( ... )             : 괄호 안은 별도의 하위 쉘에서 실행된다. 그 안에서 cd 로 이동해도 이 스크립트의 현재 위치는 바뀌지 않는다.
    #   cd 폴더 && 명령      : cd 가 성공해야 뒤의 명령을 실행한다.
    #   변수=값 명령         : 명령 앞에 변수=값 을 붙이면 그 명령에만 환경변수로 전달된다 (MYC_SESSIONS_ROOT).
    #   줄 끝의 \            : 명령이 다음 줄에 이어진다는 표시이다 (그래서 이 구문 중간에는 주석 줄을 넣을 수 없다).
    #   timeout 초 명령      : 정해진 시간이 넘으면 명령을 강제로 끝낸다.
    #   env 인자 명령        : rootfs_env 에 따라 MYC_ROOTFS 를 해제(-u)하거나 정해서 run_container.sh 를 실행한다.
    #   --                  : 그 뒤는 옵션이 아니라 agent-run 에게 줄 명령이라는 구분 표시.
    #   /bin/sh -c "$script": 컨테이너 안에서 스크립트 문자열을 sh 로 실행한다.
    #   >"파일" 2>&1         : 표준 출력을 파일에 쓰고, 오류 출력(2번)도 같은 곳으로 보낸다. 화면에는 아무것도 안 나오고 파일에 모인다.
    # live.json 이 있으면 B안이다: 백그라운드로 띄우고 컨테이너가 살아 있는 동안 host.sh 를 실행한다 (run_live)
    if [[ $live -eq 1 ]]; then
        # 실패면 run_live 가 FAIL 메시지와 정리를 마쳤다
        run_live "$dir" "$name" "$script" "$ready" || return 1
        # 성공하면 agent-run 의 종료 코드를 받는다
        rc="$LIVE_RC"
    else
    ( cd "$SRC_DIR" && MYC_SESSIONS_ROOT="$SESS_ROOT" \
        timeout "$AGENT_TIMEOUT_S" env "${rootfs_env[@]}" ./run_container.sh agent-run -- /bin/sh -c "$script" ) \
        >"$WORK/$name.agent.out" 2>&1
    # $? : 바로 앞 명령(위의 ( ... ) 전체)의 종료 코드를 rc 에 저장한다. 다른 명령을 실행하면 $? 가 바뀌므로 바로 저장해야 한다.
    rc=$?
    fi

    # 세션 ID 추출. agent-run 이 "[*] 세션 시작: <세션ID> (cgroup_id=...)" 를 출력한다.
    # sed -n 's/찾을패턴/바꿀내용/p' : 패턴과 맞는 줄에서 괄호로 묶은 부분(\( \) 안, 세션 ID)만 남겨 출력한다.
    #    -n 과 끝의 p 는 "바꾼 줄만 출력" 이라는 뜻이다. [^ ]* 는 공백이 아닌 글자들, \1 은 첫 번째 괄호가 잡은 내용이다.
    # head -1 : 첫 줄만 쓴다.
    # 이 때문에 agent-run 이 출력하는 "[*] 세션 시작: <ID> (cgroup_id=..." 형식에 의존한다 (위 "알려진 한계").
    sid="$(sed -n 's/^\[\*\] 세션 시작: \([^ ]*\) (cgroup_id=.*/\1/p' "$WORK/$name.agent.out" | head -1)"
    # 같은 줄의 cgroup_id=<값> 도 뽑는다 (런타임 검사의 맵 키). 닫는 괄호 전까지가 값이다
    cgid="$(sed -n 's/^\[\*\] 세션 시작: [^ ]* (cgroup_id=\([^)]*\)).*/\1/p' "$WORK/$name.agent.out" | head -1)"
    # =~ : 정규식 비교 (== 는 패턴 비교, =~ 는 정규식 비교).
    # ^[A-Za-z0-9._-]+$ 는 영문, 숫자, . _ - 로만 된 문자열이다. 세션 ID 에 이상한 글자가 있으면 경로로 쓰지 않는다.
    if [[ -z "$sid" || ! "$sid" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "[FAIL] $name"
        echo "        세션 ID 를 얻지 못함 (agent-run 이 시작되지 못했다). 종료 코드 $rc"
        echo "        출력: $WORK/$name.agent.out"
        return 1
    fi

    sdir="$SESS_ROOT/$sid"
    events="$sdir/events.jsonl"
    verdicts="$sdir/verdicts.jsonl"

    # 로더가 다 쓸 때까지 대기. 이벤트가 하나도 없으면 여기서 실패한다.
    # if ! 함수 ; then : 함수가 실패(return 1)를 돌려주면 (여기서는 이벤트가 안 나타나거나 안정되지 않으면) 이라는 뜻이다.
    if ! wait_settled "$events"; then
        echo "[FAIL] $name"
        echo "        세션 $sid 의 이벤트가 관측되지 않았거나 로그가 안정되지 않았다 (${SETTLE_MAX_S}초)"
        echo "        세션 폴더: $SESS_ROOT/$sid"
        return 1
    fi

    # ---- 호스트 쪽 스텝 (선택). 시나리오 폴더에 host.sh 가 있을 때만 실행한다 ----
    # agent-run 이 끝난 뒤에 러너가 호스트에서 실행한다. 컨테이너가 쓴 파일은 컨테이너가 끝난 뒤에도 upperdir 에 남아 있으므로
    # "세션이 쓴 파일을 세션 밖이 실행"하는 사건을 레이스 없이 재현할 수 있다. (러너가 세션 cgroup 밖이라고 가정한다. s01 이 이를 검증한다)
    # B안(live=1)은 host.sh 를 이미 컨테이너가 살아 있는 동안 실행했으므로 여기서 다시 실행하지 않는다
    if [[ $live -eq 0 && -f "$dir/host.sh" ]]; then
        # 이 블록에서만 쓰는 변수들. hn0 는 호스트 스텝 전의 events.jsonl 줄 수, grown 은 줄이 늘었는지, waited 는 기다린 시간(ms).
        local suffix cdir hn0 hrc grown=0 waited=0
        # ${sid##*-} : 세션 ID 에서 마지막 '-' 앞을 모두 지우고 뒷부분만 남긴다 (예: 20261012-141616-1329260 -> 1329260).
        # run_container.sh 가 세션 ID 를 "날짜-시각-스크립트PID" 로 만들고 컨테이너 폴더도 같은 번호로 이름 짓는다는 관찰에 의존한다 (이 가정이 깨지면 아래에서 실패한다).
        suffix="${sid##*-}"
        cdir="$CONTAINERS_ROOT/mycontainer-$suffix"
        # -d 폴더 : 폴더가 있으면 참. upper 폴더가 없으면 host.sh 가 쓴 파일을 찾을 수 없으니 시작하지 않고 실패한다 (fail-closed).
        if [[ ! -d "$cdir/upper" ]]; then
            echo "[FAIL] $name"
            echo "        컨테이너 폴더를 찾지 못함: $cdir/upper (host.sh 를 실행할 수 없다)"
            return 1
        fi
        # 호스트 스텝 전의 줄 수를 기억해 둔다. 이보다 늘어나야 호스트 실행이 관측된 것이다.
        hn0="$(count_lines "$events")"
        # 변수=값 명령 : 그 명령에만 환경변수를 준다. MYC_UPPER 는 host.sh 가 컨테이너 안 /tmp/payload 를 호스트에서 $MYC_UPPER/tmp/payload 로 찾는 데 쓴다.
        # timeout : host.sh 가 멈추는 경우를 막는다. 출력은 시나리오별 파일에 모은다. 종료 코드는 바로 hrc 에 저장한다.
        MYC_UPPER="$cdir/upper" timeout "$AGENT_TIMEOUT_S" /bin/bash "$dir/host.sh" >"$WORK/$name.host.out" 2>&1
        hrc=$?
        # host.sh 자체가 실패하면(종료 코드 != 0) 판정까지 가지 않고 바로 실패한다.
        if [[ $hrc -ne 0 ]]; then
            echo "[FAIL] $name"
            echo "        호스트 스텝(host.sh)이 실패했다. 종료 코드 $hrc"
            echo "        출력: $WORK/$name.host.out"
            return 1
        fi
        # 새 줄이 생길 때까지 0.1초마다 확인한다 (최대 SETTLE_MAX_S 초). 이미 안정된 로그에 wait_settled 만 부르면 새 줄이 오기 전에 "안정"으로 끝날 수 있어서 먼저 기다린다.
        while ((waited < SETTLE_MAX_S * 1000)); do
            if [[ "$(count_lines "$events")" -gt "$hn0" ]]; then grown=1; break; fi
            sleep 0.1
            waited=$((waited + 100))
        done
        # 새 줄이 안 생겼으면 판정으로 그대로 넘어간다 (판정기가 어떤 기대가 왜 안 맞는지 보여 준다). 사실만 출력 파일에 남긴다.
        if [[ $grown -ne 1 ]]; then echo "[runner] 호스트 스텝 뒤에 이벤트가 늘지 않았다 (${SETTLE_MAX_S}초)" >>"$WORK/$name.host.out"; fi
        # 새 줄이 생긴 뒤 로더가 다 쓸 때까지 한 번 더 기다린다.
        if ! wait_settled "$events"; then
            echo "[FAIL] $name"
            echo "        호스트 스텝 뒤 세션 $sid 의 로그가 안정되지 않았다 (${SETTLE_MAX_S}초)"
            echo "        세션 폴더: $SESS_ROOT/$sid"
            return 1
        fi
    fi

    # 판정. 출력은 변수에 담아 두었다가 결과에 따라 보여 준다.
    local out
    # 판정기를 실행하고, 화면에 나올 모든 글자(오류 출력 포함)를 out 변수에 담는다.
    # 판정기의 종료 코드(0 통과, 1 실패, 2 입력 오류)는 다음 줄에서 바로 jr 에 저장한다.
    out="$("$JUDGE" "$sdir" "$dir/expect.json" 2>&1)"
    jr=$?

    # 런타임 검사 (runtime.json 이 있을 때만). 판정 결과와 상관없이 실행해서 어긋난 것을 모두 보여 준다
    # rtr 은 런타임 검사의 결과 (0 통과, 1 실패), rt_out 은 어긋난 항목의 설명이다
    rtr=0
    rt_out=""
    if [[ -f "$dir/runtime.json" ]]; then
        # 출력은 변수에 담고, 종료 코드는 바로 rtr 에 저장한다
        rt_out="$(run_runtime_checks "$dir/runtime.json" "$sid" "$rc" "$cgid" "$sdir")"
        rtr=$?
    fi

    local nev nvd
    nev="$(count_lines "$events")"
    nvd="$(count_lines "$verdicts")"

    # -eq : 숫자가 같다. jr 이 0 이면 판정 통과.
    # 판정과 런타임 검사가 모두 통과해야 PASS 이다
    if [[ $jr -eq 0 && $rtr -eq 0 ]]; then
        echo "[PASS] $name   (세션 $sid, 이벤트 $nev줄, 판정/대응 $nvd줄)"
        # <<<"$out" : 변수 내용을 print_judge 의 입력으로 넣는다 (here-string). --keep 이면 통과한 검사도 전부 보여 준다.
        [[ $KEEP -eq 1 ]] && print_judge 1 <<<"$out"
        return 0
    fi

    echo "[FAIL] $name   (세션 $sid, 이벤트 $nev줄, 판정/대응 $nvd줄)"
    if [[ $jr -eq 2 ]]; then
        echo "        판정기 입력 오류: $out"
    elif [[ $jr -ne 0 ]]; then
        # 판정이 실패했을 때만 판정 내용을 보여 준다 (런타임 검사만 실패했으면 판정 쪽은 조용하다)
        print_judge 0 <<<"$out"
    fi
    # 런타임 검사가 실패했으면 어긋난 항목을 들여써서 보여 준다
    if [[ $rtr -ne 0 ]]; then
        sed 's/^/        /' <<<"$rt_out"
    fi
    # host.sh 스텝이 있었으면 그 출력 위치도 알려 준다 (실패 원인이 호스트 쪽에 있을 수 있다)
    [[ -f "$WORK/$name.host.out" ]] && echo "        호스트 스텝 출력: $WORK/$name.host.out"
    echo "        세션 폴더: $SESS_ROOT/$sid"
    return 1
}

# ---------------------------------------------------------------------------------------------
# 메인
# ---------------------------------------------------------------------------------------------
# 여기부터 실제 실행이다. 위에서 정의한 함수들을 순서대로 부른다.
preflight

# mktemp -d : 임시 폴더를 새로 만들고 그 경로를 출력한다. XXXXXX 는 무작위 글자로 바뀐다 (실행할 때마다 다른 폴더).
# 작업 폴더의 상위는 평소 /tmp 이다. 테스트(tools/test_runner.sh)만 MYC_SCEN_TMP 로 자기 전용 폴더를 준다 (끝날 때 그 폴더만 지우려고).
WORK="$(mktemp -d "${MYC_SCEN_TMP:-/tmp}/myc_scen.XXXXXX")"
# mktemp 가 실패하면 (예: MYC_SCEN_TMP 가 없는 폴더) WORK 가 비어 아래 경로가 / 바로 밑을 가리키게 된다. 그 전에 멈춘다
if [[ -z "$WORK" ]]; then
    # 이유를 알리고 시작하지 않는다 (아직 로더를 띄우기 전이라 정리할 것이 없다)
    echo "[runner] 작업 폴더를 만들지 못함 (상위: ${MYC_SCEN_TMP:-/tmp}). 시작하지 않는다" >&2
    exit 2
fi
SESS_ROOT="$WORK/sessions"
# mkdir -p : 중간 폴더까지 한 번에 만들고, 이미 있어도 오류 없이 넘어간다.
# by-cgroup 은 "cgroup id -> 세션 ID" 링크가 들어갈 폴더이다 (4일차 내용).
mkdir -p "$SESS_ROOT/by-cgroup"
# 변수 초기화. LOADER_PID 는 로더의 프로세스 번호, ANY_FAIL 은 "하나라도 실패했는가" 표시이다.
LOADER_PID=""
ANY_FAIL=0

# ---- 반복 모드(--repeat)의 누수 점검 준비 ----
# 스냅샷은 작업 폴더 안 leak/ 에 모은다. 반복 모드에서는 결과를 나중에 봐야 하므로 성공해도 작업 폴더를 남긴다 (KEEP=1)
LEAK_DIR="$WORK/leak"
# 점검기 snapshot 을 부른다. 인자: 라벨, 라운드 수, 지금까지 실행한 세션 수
# 러너가 쓰는 경로를 환경변수로 넘겨 같은 곳을 세게 한다. 로더가 안 떠 있으면 LOADER_PID 가 비어 FD 와 RSS 는 비워 둔다
leak_snapshot() {
    # 점검기를 실행하고 출력은 leak/snapshot.log 에 모은다. 종료 코드를 그대로 돌려준다
    MYC_LEAK_SESS_ROOT="$SESS_ROOT" MYC_LEAK_SELF_WORK="$WORK" MYC_LEAK_TMP="${MYC_SCEN_TMP:-/tmp}" \
        MYC_LEAK_CGROUP_ROOT="$CHECK_CGROUP_ROOT" MYC_LEAK_CONTAINERS_ROOT="$CONTAINERS_ROOT" \
        MYC_LEAK_BPFTOOL="$BPFTOOL" MYC_LEAK_PIN="$SESSION_CGROUPS_PIN" MYC_LEAK_LOADER_PID="$LOADER_PID" \
        "$LEAK_CHECK" snapshot "$LEAK_DIR" "$1" "$2" "$3" >>"$LEAK_DIR/snapshot.log" 2>&1
}
# 스냅샷이 실패하면 반복을 믿을 수 없으므로 멈춘다 (종료 코드 2). 인자는 leak_snapshot 과 같다
leak_snapshot_or_die() {
    # 성공하면 그대로 돌아간다
    leak_snapshot "$@" && return 0
    # 실패 사실과 로그 위치를 알린다
    echo "[runner] 누수 점검 스냅샷 실패 (라벨 $1). 로그: $LEAK_DIR/snapshot.log" >&2
    # 작업 폴더를 남기고 종료 코드 2 로 끝낸다 (로더는 EXIT 트랩이 끈다)
    ANY_FAIL=1
    exit 2
}
# 반복 모드이면 폴더를 만들고, 로더를 띄우기 전의 상태를 첫 스냅샷으로 남긴다
if [[ -n "$REPEAT" ]]; then
    # 성공해도 작업 폴더(스냅샷과 로그)를 남긴다
    KEEP=1
    # 스냅샷 폴더를 만든다
    mkdir -p "$LEAK_DIR"
    # 로더 시작 전 (라운드 0, 세션 0)
    leak_snapshot_or_die start 0 0
fi

# kill -0 PID  : 신호를 보내지 않고 "그 프로세스가 살아 있는지"만 확인한다.
# kill -TERM PID : 종료를 요청한다 (SIGTERM). 로더는 종료할 때 log stats 한 줄과 ring buffer drops 한 줄을 남긴다.
# wait PID     : 그 백그라운드 프로세스가 끝날 때까지 기다린다.
stop_loader() {
    if [[ -n "$LOADER_PID" ]] && kill -0 "$LOADER_PID" 2>/dev/null; then
        kill -TERM "$LOADER_PID" 2>/dev/null
        wait "$LOADER_PID" 2>/dev/null
    fi
    LOADER_PID=""
}

# 어떤 이유로 끝나든 로더를 정리하고, 실패했거나 --keep 이면 로그를 남긴다.
# (아래 trap 이 간접 호출하므로 shellcheck 가 "도달할 수 없다"고 오인하는 것을 막는다)
# shellcheck disable=SC2317
cleanup() {
    # B안 시나리오 도중에 끝나면 백그라운드 agent-run 과 세션 cgroup 을 먼저 정리한다 (없으면 아무것도 하지 않는다)
    live_cleanup >&2
    stop_loader
    # 실패했거나 --keep 이면 로그 위치를 알려 주고 남긴다. 아니면 임시 폴더를 통째로 지운다
    # (WORK 는 위에서 mktemp 로 만든 이 실행 전용 폴더이다).
    if [[ $KEEP -eq 1 || $ANY_FAIL -eq 1 ]]; then
        echo
        echo "로그 보관: $WORK"
    else
        rm -rf "$WORK"
    fi
}
# trap '명령' EXIT : 이 스크립트가 어떤 이유로 끝나든 (정상 종료, exit, 오류) 마지막에 cleanup 을 실행한다.
# 로더를 끄고 임시 폴더를 정리하는 일을 빠뜨리지 않으려는 장치이다.
trap cleanup EXIT

# 러너 전용 로더를 띄운다. 세션 루트를 인자로 넘겨서 개발용 로그 폴더와 분리한다.
# 명령 끝의 & : 백그라운드로 실행한다 (끝나기를 기다리지 않고 다음 줄로 넘어간다). 로더는 계속 떠 있어야 하기 때문이다.
# "$SESS_ROOT" 는 로더에게 주는 인자 (세션 루트). --detectors= 는 켤 탐지기 목록 (위의 RUNNER_DETECTORS).
# >파일 은 표준 출력, 2>파일 은 오류 출력(stderr)을 따로 저장한다.
# 로더의 "ready" 와 "log stats", "ring buffer drops" 는 stderr 로 나온다.
# 바로 다음 줄의 $! 는 방금 백그라운드로 시작한 프로세스의 번호(PID)이다.
"$SRC_DIR/myc_loader" --detectors="$RUNNER_DETECTORS" "$SESS_ROOT" >"$WORK/loader.out" 2>"$WORK/loader.err" &
LOADER_PID=$!

# 로더가 준비될 때까지 기다린다. 준비 메시지가 안 나오거나 도중에 죽으면 시작하지 않는다 (fail-closed).
# 로더가 "준비 완료"를 출력할 때까지 최대 READY_TIMEOUT_S 초 기다린다. 0.1 초마다 확인하므로 횟수는 초 x 10 이다.
ready=0
# for ((i = 0; i < N; i++)) : C 언어식 반복문. i 가 0 부터 N 직전까지 하나씩 늘어난다.
for ((i = 0; i < READY_TIMEOUT_S * 10; i++)); do
    # break : 반복문을 빠져나간다.
    # grep -q '^\[loader\] ready' : 줄 맨 앞(^)이 "[loader] ready" 인 줄이 있으면 성공. [ 는 정규식에서 특별한 글자라 \[ 로 쓴다.
    if grep -q '^\[loader\] ready' "$WORK/loader.err" 2>/dev/null; then ready=1; break; fi
    # 로더가 아직 살아 있는지 본다. 죽었으면 (A || B : A 가 실패하면) 더 기다리지 말고 break 한다.
    kill -0 "$LOADER_PID" 2>/dev/null || break
    sleep 0.1
done
# 준비되지 못했으면 로더가 남긴 stderr 를 들여써서 보여 주고 종료 코드 2 로 끝낸다.
# sed 's/^/  /' : 각 줄 맨 앞(^)에 공백 두 칸을 붙인다.
# LOADER_PID 는 비우지 않는다. 시간 초과로 반복문이 끝났으면 로더가 아직 살아 있을 수 있어서 cleanup 의 stop_loader 가 꺼야 한다
# (이미 죽었으면 stop_loader 의 kill -0 이 실패해 아무것도 하지 않는다).
if [[ $ready -ne 1 ]]; then
    echo "[loader] 준비되지 않았다. 로더 출력:" >&2
    sed 's/^/  /' "$WORK/loader.err" >&2
    # 실패로 표시해 WORK 폴더를 남긴다. 로더 정리는 EXIT 트랩(cleanup -> stop_loader)이 한다
    ANY_FAIL=1
    exit 2
fi

# ready 줄이 "이 러너가 켜 달라고 한 설정"으로 떠 있는지 확인한다 (fail-closed).
# 옛 로더는 --detectors=... 를 세션 루트로 잘못 읽고도 ready 를 낼 수 있어서, ready 가 나왔다는 것만으로는 믿지 않는다.
# 기대하는 줄: [loader] ready (sessions root: <루트>, mode: kill, detectors: <알파벳순 목록>)
# ready 로 시작하는 첫 줄을 꺼낸다
ready_line="$(grep -m1 '^\[loader\] ready' "$WORK/loader.err")"
# 줄 끝의 "mode: <값>, detectors: <값>)" 에서 mode 값만 뽑는다. 형식이 다르면 빈 문자열
ready_mode="$(sed -n 's/^\[loader\] ready (sessions root: .*, mode: \([^,]*\), detectors: [^)]*)$/\1/p' <<<"$ready_line")"
# 같은 자리에서 detectors 값만 뽑는다. 형식이 다르면 빈 문자열
ready_dets="$(sed -n 's/^\[loader\] ready (sessions root: .*, mode: [^,]*, detectors: \([^)]*\))$/\1/p' <<<"$ready_line")"
# 기대 목록을 쉼표로 나눠 한 줄에 하나씩 -> 정렬 -> 다시 쉼표로 잇는다.
# LC_ALL=C 는 로더의 strcmp 와 같은 바이트 순서로 정렬하게 한다 (로캘에 따라 순서가 달라지지 않게)
want_dets="$(tr ',' '\n' <<<"$RUNNER_DETECTORS" | LC_ALL=C sort | paste -sd, -)"
# 모드는 kill 이어야 하고 탐지기 목록은 정확히 같아야 한다. 하나라도 다르면 시작하지 않는다
if [[ "$ready_mode" != "kill" || "$ready_dets" != "$want_dets" ]]; then
    # 무엇을 기대했고 무엇이 왔는지 보여 준다 (옛 형식이면 mode/detectors 가 빈 값으로 보인다)
    echo "[loader] ready 줄이 기대와 다르다 (옛 로더이거나 설정이 다름). 시작하지 않는다" >&2
    echo "  기대: mode: kill, detectors: $want_dets" >&2
    echo "  실제: mode: '${ready_mode}', detectors: '${ready_dets}'" >&2
    echo "  ready 줄: $ready_line" >&2
    # 실패로 표시해 WORK 폴더를 남긴다. LOADER_PID 는 그대로 두어 cleanup 의 stop_loader 가 로더를 끄게 한다
    ANY_FAIL=1
    exit 2
fi

# 반복 모드이면 로더가 준비된 직후(세션 0)를 스냅샷으로 남긴다. 로더 FD 의 고정분은 이 값이다
[[ -n "$REPEAT" ]] && leak_snapshot_or_die ready 0 0

echo "== 시나리오 실행 (세션 루트: $SESS_ROOT) =="
total=0
passed=0
failed_names=()
# 라운드 수. 반복 모드가 아니면 1 라운드이고 기존과 같다
ROUNDS="${REPEAT:-1}"
# 반복 모드에서 FAIL 이 나 멈췄으면 1
stopped=0
# 라운드 반복. 라운드마다 선택한 시나리오를 한 번씩 돈다
for ((round = 1; round <= ROUNDS; round++)); do
    # for dir in "$SCEN_DIR"/[sn]*/ : scenarios 아래에서 s 또는 n 으로 시작하는 폴더들을 하나씩 (패턴 [sn]*/ 가 폴더 목록으로 펼쳐진다).
    # [sn] 은 s 나 n 한 글자이다. 펼친 목록은 이름순이라 n 시나리오가 s 시나리오보다 먼저 돈다.
    for dir in "$SCEN_DIR"/[sn]*/; do
        # continue : 이번 반복을 건너뛰고 다음으로 간다. 폴더가 아니면 (패턴과 맞는 것이 없을 때 등) 건너뛴다.
        [[ -d "$dir" ]] || continue
        # ${dir%/} : 변수 값의 끝에 있는 / 를 한 번 떼어낸다 (위 패턴이 붙인 마지막 /).
        dir="${dir%/}"
        name="$(basename "$dir")"
        # --only 패턴이 있으면 이름이 맞는 것만 실행한다 (selected 함수 참고)
        selected "$name" || continue

        # $(( )) 는 계산이다. 시나리오 개수를 하나 센다.
        total=$((total + 1))
        # if 뒤에 함수를 바로 쓰면 그 함수의 종료 코드로 분기한다 (0 이면 참). run_one 은 통과하면 0 을 돌려준다.
        if run_one "$dir"; then
            passed=$((passed + 1))
        else
            # 배열에 원소 추가. 실패한 시나리오 이름을 모아 두었다가 요약에서 보여 준다.
            failed_names+=("$name")
            ANY_FAIL=1
            # 반복 모드에서는 한 번이라도 FAIL 이면 바로 멈춘다 (작업 폴더는 남는다)
            if [[ -n "$REPEAT" ]]; then
                # 멈췄다고 표시하고 안쪽 반복을 빠져나간다
                stopped=1
                break
            fi
        fi
    done
    # 멈췄으면 라운드 반복도 빠져나간다
    [[ $stopped -eq 1 ]] && break
    # 반복 모드에서는 K 라운드마다(기본 10, --leak-interval) 스냅샷을 남긴다 (로더가 떠 있는 상태)
    if [[ -n "$REPEAT" ]] && ((round % ${LEAK_INTERVAL:-10} == 0)); then
        # 라벨, 라운드 수, 지금까지 실행한 세션 수
        leak_snapshot_or_die "r$round" "$round" "$total"
    fi
done
# 반복 모드에서 끝까지 돌았으면 로더를 끄기 전에 마지막 스냅샷을 남긴다 (FD 와 RSS 를 보려면 로더가 떠 있어야 한다)
if [[ -n "$REPEAT" && $stopped -eq 0 ]]; then
    # 라벨, 마지막 라운드 수, 전체 세션 수
    leak_snapshot_or_die end "$ROUNDS" "$total"
fi
# 멈췄으면 그 사실을 알린다. 비교는 하지 않는다 (반복을 다 돌지 않아 선형과 포화 판정이 의미가 없다)
if [[ $stopped -eq 1 ]]; then
    echo "[runner] 반복 중 FAIL 로 멈춤 (라운드 $round, 세션 $total). 누수 비교는 하지 않는다"
fi

# 패턴과 맞는 시나리오가 하나도 없으면 "통과"처럼 보이지 않게 오류로 끝낸다 (종료 코드 2).
# ${FILTERS[*]:-전체} 는 패턴이 없으면 "전체" 라고 표시한다.
if ((total == 0)); then
    echo "실행한 시나리오가 없다 (패턴: '${FILTERS[*]:-전체}')" >&2
    ANY_FAIL=1
    exit 2
fi

# ---------------------------------------------------------------------------------------------
# 인프라 검증. 시나리오 판정과 별개로, 로그 시스템 자체가 건강했는지 본다.
# ---------------------------------------------------------------------------------------------
stop_loader      # 종료 시 로더가 log stats 한 줄과 ring buffer drops 한 줄을 stderr 로 남긴다

infra_fail=0
echo
echo "== 인프라 검증 =="

# 1) 로그 유실이 없었는가 (로더의 log stats 줄에서 lost 값을 읽는다)
# grep 'log stats' 파일 | tail -1 : log stats 가 들어간 줄들 중 마지막 줄만 쓴다 (| 는 앞 명령의 출력을 뒤 명령의 입력으로 넘긴다).
stats_line="$(grep 'log stats' "$WORK/loader.err" | tail -1)"
# sed 로 lost=숫자 의 숫자 부분만 뽑는다. <<<"$stats_line" 는 변수 내용을 입력으로 준다. 못 찾으면 빈 문자열이 된다.
lost="$(sed -n 's/.*lost=\([0-9][0-9]*\).*/\1/p' <<<"$stats_line")"
# -z : 빈 문자열이면 (log stats 줄이 없으면) 확인할 수 없으므로 실패로 본다.
# elif [[ "$lost" -ne 0 ]] : lost 가 0 이 아니면 실패.   else : 0 이면 통과.
if [[ -z "$lost" ]]; then
    echo "[FAIL] 로그 유실 확인: 로더의 log stats 줄을 찾지 못했다"
    infra_fail=1
elif [[ "$lost" -ne 0 ]]; then
    echo "[FAIL] 로그 유실 확인: lost=$lost  ($stats_line)"
    infra_fail=1
else
    # ${stats_line#\[loader\] } : 변수 값의 앞쪽에서 "[loader] " 를 떼어낸 나머지.
    echo "[PASS] 로그 유실 없음  (${stats_line#\[loader\] })"
fi

# 3) ring buffer 드롭 확인: 버퍼가 가득 차서 커널이 버린 이벤트가 없었는가 (로더의 ring buffer drops 줄에서 읽는다)
# 이벤트가 버려지면 판정기의 "기대 정확히 0개" 검사가 거짓 PASS 가 될 수 있어서, 하나라도 버려졌으면 실패로 본다.
# 줄이 없거나 로더가 값을 읽지 못했어도 0 으로 여기지 않고 실패로 본다 (모르는 것을 0 으로 보지 않는다, fail-closed).
# 'ring buffer drops' 가 들어간 줄들 중 마지막 줄만 고른다. 그런 줄이 없으면 빈 문자열이 된다.
drops_line="$(grep 'ring buffer drops' "$WORK/loader.err" | tail -1)"
# 그 줄에서 exec= 뒤의 숫자만 뽑는다. 숫자가 없으면 (확인 실패 줄 등) 빈 문자열이 된다.
drop_exec="$(sed -n 's/.*exec=\([0-9][0-9]*\).*/\1/p' <<<"$drops_line")"
# 같은 줄에서 tag_hit= 뒤의 숫자만 뽑는다. 숫자가 없으면 빈 문자열이 된다.
drop_tag="$(sed -n 's/.*tag_hit=\([0-9][0-9]*\).*/\1/p' <<<"$drops_line")"
# 줄 자체가 없으면 (로더가 정상 종료하지 못했거나 드롭을 출력하지 않는 로더) 확인할 수 없으므로 실패로 본다.
if [[ -z "$drops_line" ]]; then
    # 실패 이유를 출력한다.
    echo "[FAIL] ring buffer 드롭 확인: 드롭 줄을 찾지 못했다"
    # 인프라 검증 실패로 표시한다.
    infra_fail=1
# == *"확인 실패"* : 줄 어딘가에 "확인 실패" 가 들어 있으면 참이다 (로더가 드롭 맵을 읽지 못했다는 뜻).
elif [[ "$drops_line" == *"확인 실패"* ]]; then
    # 실패 이유를 출력한다.
    echo "[FAIL] ring buffer 드롭 확인: 로더가 드롭 수를 읽지 못했다 (확인 실패)"
    # 인프라 검증 실패로 표시한다.
    infra_fail=1
# 두 값 중 하나라도 비었으면 줄 형식이 바뀐 것이다 (|| 는 "또는"). 숫자를 모르므로 실패로 본다.
elif [[ -z "$drop_exec" || -z "$drop_tag" ]]; then
    # 실패 이유를 출력한다.
    echo "[FAIL] ring buffer 드롭 확인: exec= 또는 tag_hit= 값을 해석하지 못했다"
    # 인프라 검증 실패로 표시한다.
    infra_fail=1
# -ne 0 : 0 이 아니면 참. 둘 중 하나라도 0 이 아니면 이벤트가 버려진 것이다.
elif [[ "$drop_exec" -ne 0 || "$drop_tag" -ne 0 ]]; then
    # 버려진 개수를 함께 출력한다.
    echo "[FAIL] ring buffer 드롭 확인: exec=$drop_exec tag_hit=$drop_tag (이벤트가 버려져 PASS 를 믿을 수 없다)"
    # 인프라 검증 실패로 표시한다.
    infra_fail=1
# 위 조건에 모두 걸리지 않았으면 두 값이 모두 0 이다.
else
    # 통과를 출력한다. 값은 0 이지만 읽은 값을 그대로 보여 준다.
    echo "[PASS] ring buffer 드롭 없음 (exec=$drop_exec tag_hit=$drop_tag)"
fi

# 2) 세션을 못 찾아 _unattributed 로 간 기록이 없는가 (있으면 by-cgroup 링크가 안 만들어진 것)
# -s 파일 : 파일이 있고 크기가 0 보다 크면 참. 둘 중 하나라도 내용이 있으면 실패이다
# (세션을 못 찾아서 기록이 _unattributed 로 간 것이다).
if [[ -s "$SESS_ROOT/_unattributed/events.jsonl" || -s "$SESS_ROOT/_unattributed/verdicts.jsonl" ]]; then
    echo "[FAIL] _unattributed 에 기록이 있다. run_container.sh 의 by-cgroup 링크 생성을 확인하라"
    infra_fail=1
else
    echo "[PASS] _unattributed 가 비어 있음"
fi

# [[ 조건 ]] && 명령 : 조건이 참이면 명령을 실행한다. 인프라 검증이 실패했으면 전체 실패로 표시한다.
[[ $infra_fail -eq 1 ]] && ANY_FAIL=1

# ---------------------------------------------------------------------------------------------
# 요약
# ---------------------------------------------------------------------------------------------
echo
echo "== 요약 =="
echo "시나리오 $passed/$total 통과"
# ${#failed_names[@]} : 배열 원소 개수.   "${failed_names[*]}" : 원소를 공백으로 이어서 한 줄로.
if ((${#failed_names[@]} > 0)); then
    echo "실패: ${failed_names[*]}"
fi
[[ $infra_fail -eq 1 ]] && echo "인프라 검증 실패"

# 반복 모드이고 끝까지 돌았으면 누수 비교를 한다. 0 합격, 1 누수나 기준 위반, 2 판정 불가
leak_rc=0
if [[ -n "$REPEAT" && $stopped -eq 0 ]]; then
    echo
    echo "== 누수 점검 ($ROUNDS 라운드, 세션 $total, 스냅샷: $LEAK_DIR) =="
    # 비교표를 그대로 보여 준다. 기준값은 점검기의 환경변수(MYC_LEAK_FD_EXTRA, MYC_LEAK_RSS_LIMIT_KB)로 바꾼다
    "$LEAK_CHECK" compare "$LEAK_DIR"
    # 종료 코드를 바로 저장한다
    leak_rc=$?
fi

# 마지막: 실패가 하나라도 있었으면 종료 코드 1, 아니면 0 이다. 이 값을 다른 스크립트나 CI 가 읽는다.
# (exit 가 실행된 뒤에도 EXIT 트랩이 마지막으로 cleanup 을 실행한다.)
# "결과:" 줄은 test_runner 가 '끝까지 실행됨'의 표지로 쓴다. 문구를 바꾸면 test_runner 도 고쳐야 한다.
if [[ $ANY_FAIL -eq 1 ]]; then
    echo "결과: FAILED"
    exit 1
fi
# 누수 비교가 실패(1)면 실패로, 판정 불가(2)면 시작하지 못한 것과 같은 2 로 끝낸다
if [[ $leak_rc -eq 1 ]]; then
    echo "결과: FAILED (누수 점검)"
    exit 1
fi
if [[ $leak_rc -ne 0 ]]; then
    # 2 와 그 밖의 값은 판정하지 못한 것으로 본다 (합격으로 치지 않는다)
    echo "결과: 누수 판정 불가 (leak_check compare 종료 코드 $leak_rc)"
    exit 2
fi
echo "결과: ALL PASSED"
exit 0
