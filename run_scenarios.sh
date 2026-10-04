#!/bin/bash
#
# run_scenarios.sh  -  시나리오 회귀 테스트 러너
#
# ===== 이 파일의 역할 =====
# scenarios/ 아래의 시나리오를 하나씩 실제로 실행하고(agent-run), 세션 로그가 기대한 모양인지 판정해서
# PASS/FAIL 을 출력한다. 한 명령으로 전체를 돌린다.
#
#     sudo ./run_scenarios.sh                # 전체
#     sudo ./run_scenarios.sh --only 's99*'  # 이름이 맞는 시나리오만
#     sudo ./run_scenarios.sh --keep         # 성공해도 로그를 보관
#
# ===== 시나리오 형식 =====
#   scenarios/<이름>/run.sh        컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 넘김)
#   scenarios/<이름>/expect.json   기대하는 세션 로그 (형식은 tools/judge.sh 의 설명 참고)
# 이름은 s 로 시작해야 한다. s00~s98 은 실제 시나리오, s99 는 더미 탐지기 검증용으로 예약해 둔다.
#
# ===== 러너가 하는 일 (순서) =====
#   1. 사전 점검(preflight): 이 도구를 믿고 돌릴 수 있는 환경인가
#   2. 임시 폴더를 만들고, 그 안을 세션 루트로 쓰는 "러너 전용 로더"를 띄운다
#      (개발 중에 쓰는 로그 폴더 /var/lib/mycontainer/sessions 를 더럽히지 않으려고 분리한다)
#   3. 시나리오마다: agent-run 실행 -> 세션 ID 추출 -> 로더가 다 쓸 때까지 대기 -> 판정
#   4. 로더를 종료하고 인프라 검증 (로그 유실 0, _unattributed 비어 있음)
#   5. 요약 출력. 하나라도 실패하면 종료 코드 1
#
# ===== 종료 코드 =====
#   0 : 전부 통과      1 : 하나 이상 실패      2 : 환경 문제로 시작하지 못함 (사전 점검 실패 등)
#   "시작하지 못함(2)"과 "테스트가 실패함(1)"을 구분해서, 환경이 틀려서 아무것도 안 돌았는데
#   성공처럼 보이는 일을 막는다.
#
# ===== 알려진 한계 =====
#   - 세션 ID 는 agent-run 이 출력하는 "[*] 세션 시작: <ID> ..." 줄에서 뽑는다. 그 출력 형식이 바뀌면 깨진다.
#   - ring buffer 에서 이벤트가 유실돼도 센 값이 없어서 알 수 없다 (드롭 카운터는 2주차 예정).
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
SCEN_DIR="$HERE/scenarios"
JUDGE="$HERE/tools/judge.sh"

# 대문자 이름의 변수는 "상수처럼 쓰는 설정값"이라는 관례이다 (쉘 문법상 특별한 것은 아니다). 필요하면 값만 조정한다.
SETTLE_MS=500           # 이벤트 로그가 이 시간 동안 늘지 않으면 로더가 다 썼다고 본다
SETTLE_MAX_S=10         # 이 시간을 넘겨도 안정되지 않으면 실패로 본다
AGENT_TIMEOUT_S=60      # 시나리오 하나가 이 시간을 넘기면 중단한다
READY_TIMEOUT_S=10      # 로더가 준비되기를 기다리는 최대 시간

# 옵션 상태. KEEP=1 이면 성공해도 로그를 보관한다. FILTER 는 --only 로 받은 이름 패턴이다.
KEEP=0
FILTER=""

# 함수 정의 : 이름() { ... }. 부를 때는 이름만 쓴다 (usage). 함수 안의 $1 은 함수에 준 인자이다 (스크립트의 $1 과 별개).
# sed -n '3,12p' "$0" : 이 파일 자신의 3~12번째 줄만 출력한다. 즉 --help 는 위쪽 주석의 사용법 부분을 그대로 보여 준다.
#    그래서 파일 맨 위 12줄은 줄 수를 바꾸면 안 된다 (줄이 추가되면 --help 출력이 어긋난다).
# 두 번째 sed 는 각 줄 앞의 "# " 를 지운다.
usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
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
        # --only 패턴 : 옵션 바로 뒤의 값($2)을 FILTER 에 넣고, 옵션과 값 둘을 소비한다 (shift 2).
        #               ${2:-} 는 값이 안 왔을 때 빈 문자열을 쓰라는 뜻이다.
        --only) FILTER="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
done

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
# 시나리오 하나 실행. 통과하면 0, 실패하면 1.
# ---------------------------------------------------------------------------------------------
run_one() {
    # 반환값: 통과하면 return 0, 실패하면 return 1. 부르는 쪽이 if run_one ...; then 으로 성공/실패를 받는다.
    local dir="$1" name script sid sdir events verdicts rc jr
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

    # agent-run 실행. run_container.sh 는 ./mycontainer_run 을 상대 경로로 부르므로 src 로 이동해서 실행한다.
    # MYC_SESSIONS_ROOT 로 세션 로그가 러너 전용 폴더로 가게 한다.
    # timeout 은 시나리오가 멈춰 버리는 경우를 막는다.
    # 이 명령의 문법:
    #   ( ... )             : 괄호 안은 별도의 하위 쉘에서 실행된다. 그 안에서 cd 로 이동해도 이 스크립트의 현재 위치는 바뀌지 않는다.
    #   cd 폴더 && 명령      : cd 가 성공해야 뒤의 명령을 실행한다.
    #   변수=값 명령         : 명령 앞에 변수=값 을 붙이면 그 명령에만 환경변수로 전달된다 (MYC_SESSIONS_ROOT).
    #   줄 끝의 \            : 명령이 다음 줄에 이어진다는 표시이다 (그래서 이 구문 중간에는 주석 줄을 넣을 수 없다).
    #   timeout 초 명령      : 정해진 시간이 넘으면 명령을 강제로 끝낸다.
    #   --                  : 그 뒤는 옵션이 아니라 agent-run 에게 줄 명령이라는 구분 표시.
    #   /bin/sh -c "$script": 컨테이너 안에서 스크립트 문자열을 sh 로 실행한다.
    #   >"파일" 2>&1         : 표준 출력을 파일에 쓰고, 오류 출력(2번)도 같은 곳으로 보낸다. 화면에는 아무것도 안 나오고 파일에 모인다.
    ( cd "$SRC_DIR" && MYC_SESSIONS_ROOT="$SESS_ROOT" \
        timeout "$AGENT_TIMEOUT_S" ./run_container.sh agent-run -- /bin/sh -c "$script" ) \
        >"$WORK/$name.agent.out" 2>&1
    # $? : 바로 앞 명령(위의 ( ... ) 전체)의 종료 코드를 rc 에 저장한다. 다른 명령을 실행하면 $? 가 바뀌므로 바로 저장해야 한다.
    rc=$?

    # 세션 ID 추출. agent-run 이 "[*] 세션 시작: <세션ID> (cgroup_id=...)" 를 출력한다.
    # sed -n 's/찾을패턴/바꿀내용/p' : 패턴과 맞는 줄에서 괄호로 묶은 부분(\( \) 안, 세션 ID)만 남겨 출력한다.
    #    -n 과 끝의 p 는 "바꾼 줄만 출력" 이라는 뜻이다. [^ ]* 는 공백이 아닌 글자들, \1 은 첫 번째 괄호가 잡은 내용이다.
    # head -1 : 첫 줄만 쓴다.
    # 이 때문에 agent-run 이 출력하는 "[*] 세션 시작: <ID> (cgroup_id=..." 형식에 의존한다 (위 "알려진 한계").
    sid="$(sed -n 's/^\[\*\] 세션 시작: \([^ ]*\) (cgroup_id=.*/\1/p' "$WORK/$name.agent.out" | head -1)"
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

    # 판정. 출력은 변수에 담아 두었다가 결과에 따라 보여 준다.
    local out
    # 판정기를 실행하고, 화면에 나올 모든 글자(오류 출력 포함)를 out 변수에 담는다.
    # 판정기의 종료 코드(0 통과, 1 실패, 2 입력 오류)는 다음 줄에서 바로 jr 에 저장한다.
    out="$("$JUDGE" "$sdir" "$dir/expect.json" 2>&1)"
    jr=$?

    local nev nvd
    nev="$(count_lines "$events")"
    nvd="$(count_lines "$verdicts")"

    # -eq : 숫자가 같다. jr 이 0 이면 판정 통과.
    if [[ $jr -eq 0 ]]; then
        echo "[PASS] $name   (세션 $sid, 이벤트 $nev줄, 판정/대응 $nvd줄)"
        # <<<"$out" : 변수 내용을 print_judge 의 입력으로 넣는다 (here-string). --keep 이면 통과한 검사도 전부 보여 준다.
        [[ $KEEP -eq 1 ]] && print_judge 1 <<<"$out"
        return 0
    fi

    echo "[FAIL] $name   (세션 $sid, 이벤트 $nev줄, 판정/대응 $nvd줄)"
    if [[ $jr -eq 2 ]]; then
        echo "        판정기 입력 오류: $out"
    else
        print_judge 0 <<<"$out"
    fi
    echo "        세션 폴더: $SESS_ROOT/$sid"
    return 1
}

# ---------------------------------------------------------------------------------------------
# 메인
# ---------------------------------------------------------------------------------------------
# 여기부터 실제 실행이다. 위에서 정의한 함수들을 순서대로 부른다.
preflight

# mktemp -d : 임시 폴더를 새로 만들고 그 경로를 출력한다. XXXXXX 는 무작위 글자로 바뀐다 (실행할 때마다 다른 폴더).
WORK="$(mktemp -d /tmp/myc_scen.XXXXXX)"
SESS_ROOT="$WORK/sessions"
# mkdir -p : 중간 폴더까지 한 번에 만들고, 이미 있어도 오류 없이 넘어간다.
# by-cgroup 은 "cgroup id -> 세션 ID" 링크가 들어갈 폴더이다 (4일차 내용).
mkdir -p "$SESS_ROOT/by-cgroup"
# 변수 초기화. LOADER_PID 는 로더의 프로세스 번호, ANY_FAIL 은 "하나라도 실패했는가" 표시이다.
LOADER_PID=""
ANY_FAIL=0

# kill -0 PID  : 신호를 보내지 않고 "그 프로세스가 살아 있는지"만 확인한다.
# kill -TERM PID : 종료를 요청한다 (SIGTERM). 로더는 종료할 때 log stats 한 줄을 남긴다.
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
# "$SESS_ROOT" 는 로더에게 주는 인자 (세션 루트). >파일 은 표준 출력, 2>파일 은 오류 출력(stderr)을 따로 저장한다.
# 로더의 "ready" 와 "log stats" 는 stderr 로 나온다.
# 바로 다음 줄의 $! 는 방금 백그라운드로 시작한 프로세스의 번호(PID)이다.
"$SRC_DIR/myc_loader" "$SESS_ROOT" >"$WORK/loader.out" 2>"$WORK/loader.err" &
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
# LOADER_PID="" 는 cleanup 이 이미 죽은 프로세스를 끄려고 하지 않게 비워 두는 것이다.
if [[ $ready -ne 1 ]]; then
    echo "[loader] 준비되지 않았다. 로더 출력:" >&2
    sed 's/^/  /' "$WORK/loader.err" >&2
    ANY_FAIL=1
    LOADER_PID=""
    exit 2
fi

echo "== 시나리오 실행 (세션 루트: $SESS_ROOT) =="
total=0
passed=0
failed_names=()
# for dir in "$SCEN_DIR"/s*/ : scenarios 아래에서 s 로 시작하는 폴더들을 하나씩 (패턴 s*/ 가 폴더 목록으로 펼쳐진다).
for dir in "$SCEN_DIR"/s*/; do
    # continue : 이번 반복을 건너뛰고 다음으로 간다. 폴더가 아니면 (패턴과 맞는 것이 없을 때 등) 건너뛴다.
    [[ -d "$dir" ]] || continue
    # ${dir%/} : 변수 값의 끝에 있는 / 를 한 번 떼어낸다 (위 패턴이 붙인 마지막 /).
    dir="${dir%/}"
    name="$(basename "$dir")"
    # --only 패턴이 있으면 이름이 맞는 것만 실행 (패턴은 셸 글롭이라 따옴표 없이 비교한다)
    # shellcheck disable=SC2053
    if [[ -n "$FILTER" && "$name" != $FILTER ]]; then continue; fi

    # $(( )) 는 계산이다. 시나리오 개수를 하나 센다.
    total=$((total + 1))
    # if 뒤에 함수를 바로 쓰면 그 함수의 종료 코드로 분기한다 (0 이면 참). run_one 은 통과하면 0 을 돌려준다.
    if run_one "$dir"; then
        passed=$((passed + 1))
    else
        # 배열에 원소 추가. 실패한 시나리오 이름을 모아 두었다가 요약에서 보여 준다.
        failed_names+=("$name")
        ANY_FAIL=1
    fi
done

# 패턴과 맞는 시나리오가 하나도 없으면 "통과"처럼 보이지 않게 오류로 끝낸다 (종료 코드 2).
# ${FILTER:-전체} 는 FILTER 가 비어 있으면 "전체" 라고 표시한다.
if ((total == 0)); then
    echo "실행한 시나리오가 없다 (패턴: '${FILTER:-전체}')" >&2
    ANY_FAIL=1
    exit 2
fi

# ---------------------------------------------------------------------------------------------
# 인프라 검증. 시나리오 판정과 별개로, 로그 시스템 자체가 건강했는지 본다.
# ---------------------------------------------------------------------------------------------
stop_loader      # 종료 시 로더가 log stats 한 줄을 stderr 로 남긴다

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

# 마지막: 실패가 하나라도 있었으면 종료 코드 1, 아니면 0 이다. 이 값을 다른 스크립트나 CI 가 읽는다.
# (exit 가 실행된 뒤에도 EXIT 트랩이 마지막으로 cleanup 을 실행한다.)
if [[ $ANY_FAIL -eq 1 ]]; then
    echo "결과: FAILED"
    exit 1
fi
echo "결과: ALL PASSED"
exit 0
