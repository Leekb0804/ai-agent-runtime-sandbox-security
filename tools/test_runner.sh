#!/bin/bash
#
# tools/test_runner.sh
#
# ===== 이 파일의 역할 =====
# 러너(run_scenarios.sh)의 "흐름"이 맞는지 검증한다. 진짜 로더와 진짜 agent-run 대신
# tools/mock 의 가짜를 끼워서, root 권한, 커널, eBPF, 컨테이너 없이 돈다.
#
#   test_judge.sh  : 로그를 기대값과 비교하는 "판정" 로직을 검증
#   test_runner.sh : 로더 시작, 시나리오 실행, 대기, 판정, 정리, 종료 코드의 "흐름"을 검증
#   실제 환경    : sudo ./run_scenarios.sh (진짜 로더와 컨테이너로 전체를 확인)
#
# ===== 왜 필요한가 =====
# 러너가 FAIL 을 낼 수 있다는 것, 환경이 틀리면 시작을 거부한다는 것, 로그가 늦게 써져도 기다린다는 것을
# 먼저 증명해 둬야 진짜 환경의 PASS 를 믿을 수 있다. 항상 PASS 하는 테스트는 아무것도 검증하지 못한다.
#
# 사용법: tools/test_runner.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 이 파일의 구조: check, expect_text 함수를 정의하고, 케이스마다 한두 줄씩 호출한다.
# 문법은 tools/judge.sh 와 run_scenarios.sh 의 주석을 참고한다.
# set -u : 값이 정해지지 않은 변수를 쓰면 오류로 멈춘다.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# 검사 대상은 러너(run_scenarios.sh)이다. 진짜 로더와 컨테이너 대신 tools/mock 의 가짜를 끼워 넣고 실행한다.
RUNNER="$ROOT/run_scenarios.sh"

# 러너 테스트 전용 시나리오 폴더. 실제 scenarios/ 에 시나리오가 늘어도 이 테스트가 흔들리지 않게 s00 과 s99 만 링크로 건다.
# 링크이므로 원본 시나리오가 바뀌면 테스트도 같은 것을 본다. 호스트 스텝 테스트가 만드는 임시 시나리오도 이 폴더 안에 둔다.
SCEN="$(mktemp -d)"
ln -s "$ROOT/scenarios/s00_benign" "$SCEN/s00_benign"
ln -s "$ROOT/scenarios/s99_dummy_block" "$SCEN/s99_dummy_block"
# 호스트 스텝 테스트가 컨테이너 폴더를 둘 임시 폴더 (mock agent-run 이 이 아래에 mycontainer-<번호>/upper 를 만든다)
CONT="$(mktemp -d)"
# 런타임 검사 테스트용: 가짜 cgroup 루트(러너가 cgroup_gone 으로 확인하는 곳)와 가짜 bpftool 의 호출 횟수 파일
CGR="$(mktemp -d)"
MAPCOUNT="$(mktemp)"
# 가짜 로더가 받은 인자와 PID 를 적는 파일 (MOCK_LOADER_RECORD). 로더 옵션 묶음에서 쓴다
LREC="$(mktemp)"
# check 가 러너에 넘길 추가 인자 (예: --only 패턴). 기본은 없음
RUNNER_ARGS=()

# 러너가 만드는 작업 폴더(myc_scen.XXXXXX)를 모을 이 테스트 전용 폴더.
# 러너는 실패하면 작업 폴더를 남기는데, 이 테스트는 일부러 실패 경로를 돌리므로 그대로 두면 /tmp 에 계속 쌓인다.
# 그래서 러너에 MYC_SCEN_TMP 로 이 폴더를 주고, 끝날 때 이 폴더 하나만 지운다 (/tmp/myc_scen.* 를 glob 으로 지우지 않는다).
# ${TMPDIR:-/tmp} : TMPDIR 가 있으면 그 아래, 없으면 /tmp 아래에 만든다
SCENTMP="$(mktemp -d "${TMPDIR:-/tmp}/myc_trtmp.XXXXXX")"
# 만들지 못했으면 정리할 대상도 정할 수 없으므로 바로 멈춘다
[[ -n "$SCENTMP" && -d "$SCENTMP" ]] || { echo "[test_runner] 전용 임시 폴더를 만들지 못함" >&2; exit 2; }
# export : 이 스크립트가 실행하는 모든 러너(check 와 풀어 쓴 호출 전부)에 이 값이 전달된다
export MYC_SCEN_TMP="$SCENTMP"

# 전용 폴더를 지운다. 안전장치를 모두 통과할 때만 rm -rf 하고, 하나라도 어긋나면 지우지 않고 이유를 알린 뒤 1 을 돌려준다.
#   remove_scen_tmp <폴더>
remove_scen_tmp() {
    # 지울 폴더 (인자)
    local d="${1-}"
    # 빈 값이면 거부 (변수가 비어 rm -rf "" 나 엉뚱한 경로가 되는 것을 막는다)
    if [[ -z "$d" ]]; then
        echo "[test_runner] 정리 거부: 지울 폴더 변수가 비었음" >&2
        return 1
    fi
    # / 이면 거부
    if [[ "$d" == "/" ]]; then
        echo "[test_runner] 정리 거부: / 는 지우지 않음" >&2
        return 1
    fi
    # 이 실행이 만든 그 폴더여야 한다 (SCENTMP 와 글자 그대로 같아야 함)
    if [[ "$d" != "$SCENTMP" ]]; then
        echo "[test_runner] 정리 거부: 이 실행이 만든 폴더가 아님: $d" >&2
        return 1
    fi
    # 이름이 mktemp 가 만든 형태(myc_trtmp. 뒤에 6글자)여야 한다. ${d##*/} 는 마지막 / 뒤의 이름
    if [[ ! "${d##*/}" =~ ^myc_trtmp\.[A-Za-z0-9]{6}$ ]]; then
        echo "[test_runner] 정리 거부: 이름이 mktemp 형태가 아님: $d" >&2
        return 1
    fi
    # 이미 없으면 할 일이 없다 (두 번 불려도 오류 아님)
    [[ -e "$d" ]] || return 0
    # 링크가 아닌 진짜 폴더이고 내 소유여야 한다 (-L 링크, -d 폴더, -O 현재 사용자 소유)
    if [[ -L "$d" || ! -d "$d" || ! -O "$d" ]]; then
        echo "[test_runner] 정리 거부: 내 소유의 폴더가 아님: $d" >&2
        return 1
    fi
    # 모든 검사를 통과했다. -- 뒤는 옵션이 아니라 경로라는 표시
    rm -rf -- "$d"
}

failures=0
# mktemp : 임시 "파일"을 만들고 경로를 출력한다 (-d 를 붙이면 폴더). 러너의 출력을 여기에 모아 두고 검사한다.
OUT="$(mktemp)"
# trap '명령' EXIT : 스크립트가 어떻게 끝나든 마지막에 그 명령을 실행한다. 여기서는 임시 파일을 지운다.
# 마지막의 remove_scen_tmp 는 러너 작업 폴더를 모은 전용 폴더를 지운다 (안전장치는 함수 안에 있다)
trap 'rm -f "$OUT" "$MAPCOUNT" "$LREC"; rm -rf "$SCEN" "$CONT" "$CGR"; remove_scen_tmp "$SCENTMP"' EXIT

# 러너 출력(OUT 파일)에 "결과: FAILED" 줄이 있는지 확인한다. 있으면 참(0), 없으면 거짓(1)을 돌려준다.
# 러너가 종료 코드 1 로 끝나는 exit 는 run_scenarios.sh 맨 끝 한 곳뿐이고 그 바로 앞에서 이 줄을 낸다.
# 그래서 종료 코드가 1 인데 이 줄이 없으면, 검사가 실패를 잡은 것이 아니라 러너가 중간에 중단된 것이다
# (set -u 의 unbound variable 오류처럼 bash 가 스스로 1 로 끝내는 경우).
has_failed_result() {
    # -q 출력 없이 있는지만, -F 글자 그대로, -- 뒤는 찾을 문자열. grep 의 종료 코드가 이 함수의 결과가 된다.
    grep -qF -- "결과: FAILED" "$OUT"
}

# 가짜 구현으로 러너를 실행하고 종료 코드를 확인한다.
#   check "<설명>" <기대 종료 코드> [환경변수=값 ...]
# 기대 코드가 1 이면 결과 줄("결과: FAILED")도 있어야 통과한다 (러너 중단과 정상 실패를 구분하려는 것).
# 러너 출력에 반드시 들어 있어야 하는 문구는 직후에 expect_text 로 확인한다.
check() {
    local msg="$1" want="$2" got
    # shift 2 : 앞의 두 인자(설명, 기대 코드)를 버리고 나머지를 앞으로 당긴다.
    # 남은 인자($@)는 MOCK_MODE=normal 같은 "환경변수=값" 들이다.
    shift 2
    # env 변수=값 ... 명령 : 그 환경변수들을 지정해서 명령을 실행한다. "$@" 는 남은 인자 전체이다.
    # 즉 이 줄은 MYC_RUNNER_TEST=1 MYC_SRC_DIR=tools/mock MOCK_MODE=... ./run_scenarios.sh 와 같다.
    # 출력과 오류 출력은 모두 OUT 파일에 모은다 (>"$OUT" 2>&1). 바로 다음 줄에서 종료 코드를 got 에 저장한다.
    # "${RUNNER_ARGS[@]}" 는 러너에 줄 추가 인자이다 (런타임 검사 묶음에서만 --only 를 넣는다)
    env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MYC_CONTAINERS_ROOT="$CONT" "$@" "$RUNNER" "${RUNNER_ARGS[@]}" >"$OUT" 2>&1
    got=$?
    # 러너의 종료 코드가 기대와 다르면 실패.
    if [[ "$got" != "$want" ]]; then
        printf '  FAIL  %s (기대 종료 코드 %s, 실제 %s)\n' "$msg" "$want" "$got"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    # 종료 코드는 1 로 같지만 결과 줄이 없으면 실패. ! 는 함수의 결과(참/거짓)를 뒤집는다.
    elif [[ "$want" == 1 ]] && ! has_failed_result; then
        # 왜 실패인지 알려 준다. 종료 코드만 보면 통과처럼 보이는 경우라서 문구를 따로 둔다.
        printf '  FAIL  %s (종료 코드는 1 이지만 "결과: FAILED" 가 없음 - 러너가 중간에 중단됐을 수 있음)\n' "$msg"
        # 러너 출력을 들여써서 보여 준다 (중단 지점과 오류 메시지를 확인하려고).
        sed 's/^/        /' "$OUT"
        # 실패 개수를 하나 늘린다.
        failures=$((failures + 1))
    # 위 두 경우가 아니면 통과.
    else
        printf '  PASS  %s\n' "$msg"
    fi
}

# 러너 출력(OUT 파일)에 특정 문구가 들어 있는지 확인하는 함수이다.
# grep 옵션: -q 화면에 출력하지 않고 있는지만 확인, -F 정규식이 아니라 글자 그대로 찾기,
# -- 뒤는 옵션이 아니라 찾을 문자열이라는 표시 (문구가 - 로 시작해도 안전하다).
expect_text() {
    local msg="$1" text="$2"
    if grep -qF -- "$text" "$OUT"; then
        printf '  PASS  %s\n' "$msg"
    else
        printf '  FAIL  %s (출력에 "%s" 가 없음)\n' "$msg" "$text"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    fi
}

# 자체 점검 모드: 맨 아래 "[임시 폴더 정리]" 케이스가 이 스크립트를 MYC_TR_SELFTEST=1 로 한 번 더 실행할 때만 들어온다.
# 실패하는 러너를 한 번 돌려 작업 폴더를 남기게 하고, 그 폴더가 전용 폴더 안에 실제로 있는지 출력한 뒤 바로 끝낸다.
# 끝날 때 위의 trap 이 전용 폴더를 지워야 한다. 지워졌는지는 바깥(부른 쪽)이 확인한다 (자기 trap 의 결과는 스스로 볼 수 없어서).
if [[ "${MYC_TR_SELFTEST:-0}" == 1 ]]; then
    # 로그가 기대와 달라 종료 코드 1 로 끝나는 경로 -> 러너가 작업 폴더를 남긴다
    env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MYC_CONTAINERS_ROOT="$CONT" MOCK_MODE=wrong "$RUNNER" >"$OUT" 2>&1
    # 러너가 알려 준 보관 위치 ("로그 보관: <경로>" 줄)
    kept="$(sed -n 's/^로그 보관: //p' "$OUT")"
    # 전용 폴더 경로와 러너 종료 코드를 바깥에 알린다
    echo "selftest-dir=$SCENTMP"
    echo "selftest-kept=$kept"
    # 정리 직전에 둘 다 실제로 있는지 알린다 (없는데 "지워졌다"고 통과하는 것을 막는 단언용)
    [[ -d "$SCENTMP" ]] && echo "selftest-dir-exists=1"
    [[ -n "$kept" && -d "$kept" ]] && echo "selftest-kept-exists=1"
    # 여기서 끝낸다. trap 이 정리한다
    exit 0
fi

# check 는 가짜 구현(MYC_RUNNER_TEST=1 과 MYC_SRC_DIR=tools/mock 은 자동으로 붙는다)에 MOCK_MODE 를 바꿔 가며 러너를 실행한다.
# MOCK_MODE 의 뜻은 tools/mock/run_container.sh 의 머리 주석 참고.
echo "[정상 흐름]"
check "가짜 로그가 기대와 맞으면 전체 통과 (종료 코드 0)" 0 MOCK_MODE=normal
expect_text "요약에 2개 모두 통과로 표시" "시나리오 2/2 통과"
expect_text "인프라 검증도 통과" "로그 유실 없음"
# 가짜 로더는 기본으로 exec=0 tag_hit=0 을 보고한다. 드롭 검사의 PASS 경로가 실제로 출력되는지 확인한다.
expect_text "ring buffer 드롭 검사도 통과" "[PASS] ring buffer 드롭 없음"

echo "[실패를 잡아내는가]"
check "로그가 기대와 다르면 FAIL (종료 코드 1)" 1 MOCK_MODE=wrong
expect_text "어느 검사가 왜 실패했는지 출력" "기대 정확히 0개, 실제"
expect_text "실패한 시나리오 이름을 요약에 표시" "실패: s00_benign s99_dummy_block"
# 참고: nolog 와 unattr 케이스는 시나리오마다 이벤트가 나타나기를 SETTLE_MAX_S (10초) 기다린 뒤 실패로 판정한다.
# 시나리오가 2개이므로 케이스당 약 20초가 걸린다. 화면이 멈춘 것처럼 보여도 정상이고, 전체 소요는 약 50초이다.
check "이벤트를 하나도 못 본 세션은 FAIL (가짜 통과 방지)" 1 MOCK_MODE=nolog
expect_text "이유를 알려 줌" "관측되지 않았거나"
check "로그가 _unattributed 로 가면 인프라 검증이 FAIL" 1 MOCK_MODE=unattr
expect_text "by-cgroup 링크를 의심하라고 안내" "by-cgroup 링크 생성을 확인"
# MOCK_LOST=3 : 가짜 로더(tools/mock/myc_loader)가 종료할 때 lost=3 을 보고하게 한다.
check "로더가 로그를 잃었다고 보고하면 FAIL" 1 MOCK_LOST=3
expect_text "lost 값을 보여 줌" "lost=3"
# MOCK_DROPS_EXEC=5 : 가짜 로더가 종료할 때 exec 드롭 5개를 보고하게 한다 (tag_hit 은 기본 0).
check "로더가 exec 이벤트를 버렸다고 보고하면 FAIL" 1 MOCK_DROPS_EXEC=5
expect_text "exec 드롭 수를 보여 줌" "[FAIL] ring buffer 드롭 확인: exec=5 tag_hit=0"
# MOCK_DROPS_TAG=2 : exec 는 0 이고 tag_hit 드롭만 2개. tag_hit 값도 읽는지 확인한다.
check "로더가 tag_hit 이벤트를 버렸다고 보고하면 FAIL" 1 MOCK_DROPS_TAG=2
expect_text "tag_hit 드롭 수를 보여 줌" "[FAIL] ring buffer 드롭 확인: exec=0 tag_hit=2"
# MOCK_DROPS=fail : 가짜 로더가 드롭 수 대신 "확인 실패" 를 낸다. 숫자가 없다고 0 으로 보면 안 된다.
check "로더가 드롭 수를 읽지 못했으면 FAIL" 1 MOCK_DROPS=fail
expect_text "읽기 실패를 알려 줌" "[FAIL] ring buffer 드롭 확인: 로더가 드롭 수를 읽지 못했다 (확인 실패)"
# MOCK_DROPS=none : 가짜 로더가 드롭 줄을 아예 내지 않는다. 줄이 없다고 통과로 보면 안 된다.
check "드롭 줄이 없으면 FAIL" 1 MOCK_DROPS=none
expect_text "드롭 줄이 없음을 알려 줌" "[FAIL] ring buffer 드롭 확인: 드롭 줄을 찾지 못했다"
# MOCK_DROPS=garbage : 드롭 줄은 있지만 숫자를 뽑을 수 없다. 형식이 바뀐 줄을 통과로 보면 안 된다.
check "드롭 줄의 값을 해석하지 못하면 FAIL" 1 MOCK_DROPS=garbage
expect_text "해석 실패를 알려 줌" "[FAIL] ring buffer 드롭 확인: exec= 또는 tag_hit= 값을 해석하지 못했다"

echo "[기다리는가]"
# slow 모드의 가짜 agent-run 은 바로 종료하고 로그는 그 뒤에도 0.3초 간격으로 계속 써진다.
# 러너가 그 도중에 읽지 않고 줄 수가 안정될 때까지 기다려야 통과한다 (wait_settled 가 하는 일).
check "로그가 늦게(0.3초 간격) 써져도 다 쓸 때까지 기다려서 통과" 0 MOCK_MODE=slow

echo "[호스트 스텝 (host.sh)]"
# 임시 시나리오 하나를 SCEN 에 만들고 --only 로 그것만 실행한다. 정상 s00 로그를 쓰는 mock 이므로 기대(expect.json)는 s00 과 같다.
# 시나리오 이름은 s_host 로 하고 끝나면 지운다. run.sh 에는 trigger 가 없으므로 mock 이 s00 로그를 만든다.
make_host_scn() {
    # 인자 $1 = host.sh 본문. 폴더를 새로 만들고 run.sh, expect.json, host.sh 를 쓴다.
    rm -rf "$SCEN/s_host"
    mkdir -p "$SCEN/s_host"
    echo '/bin/ls' > "$SCEN/s_host/run.sh"
    cp "$ROOT/scenarios/s00_benign/expect.json" "$SCEN/s_host/expect.json"
    printf '%s\n' "$1" > "$SCEN/s_host/host.sh"
}
# 케이스 1: host.sh 가 실패(종료 코드 3)하면 러너가 FAIL 하고 종료 코드를 알려 준다.
make_host_scn 'exit 3'
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MYC_CONTAINERS_ROOT="$CONT" MOCK_MODE=normal "$RUNNER" --only 's_host' >"$OUT" 2>&1
got=$?
# 종료 코드 1, 호스트 스텝 실패 문구, 그리고 결과 줄(has_failed_result: 러너가 끝까지 실행됐는지)을 모두 확인한다.
if [[ $got -eq 1 ]] && grep -qF "호스트 스텝(host.sh)이 실패했다. 종료 코드 3" "$OUT" && has_failed_result; then
    echo "  PASS  host.sh 가 실패하면 종료 코드를 알려 주고 FAIL"
else
    echo "  FAIL  host.sh 실패를 잡지 못함 (종료 코드 $got, 문구나 \"결과: FAILED\" 줄이 없을 수 있음)"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi
# 케이스 2: host.sh 가 컨테이너 폴더(MYC_UPPER)를 받고 그 안에 표시 파일을 남기면, 호스트 스텝이 컨테이너 폴더에서 실행된 것이다.
# 호스트 스텝 뒤에 이벤트가 늘지 않으므로 러너는 그 사실을 호스트 스텝 출력에 남기고 판정으로 넘어가 통과(s00 기대)한다.
make_host_scn 'touch "${MYC_UPPER:?}/host_ran"; echo "[host.sh] MYC_UPPER=$MYC_UPPER"'
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MYC_CONTAINERS_ROOT="$CONT" MOCK_MODE=normal "$RUNNER" --only 's_host' >"$OUT" 2>&1
got=$?
# 종료 코드 0 이고, CONT 아래 어떤 컨테이너 폴더의 upper 에 host_ran 이 생겼는지 find 로 찾는다 (-name 파일 이름, -path 경로 패턴).
if [[ $got -eq 0 ]] && [[ -n "$(find "$CONT" -path '*/upper/host_ran' -name host_ran 2>/dev/null)" ]]; then
    echo "  PASS  host.sh 가 컨테이너 폴더(MYC_UPPER)를 받아 실행됨"
else
    echo "  FAIL  host.sh 가 컨테이너 폴더에서 실행되지 않음 (종료 코드 $got)"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi
# 케이스 3: 컨테이너 폴더가 없으면(진짜 agent-run 의 폴더 이름 규칙이 깨진 경우) 시작하지 않고 FAIL 한다 (fail-closed).
# MOCK_NO_CONTAINER=1 로 mock 이 컨테이너 폴더를 만들지 않게 한다. 존재하지 않는 경로를 쓰지 않으므로 root 로 실행해도 시스템에 폴더가 생기지 않는다.
make_host_scn 'exit 0'
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MYC_CONTAINERS_ROOT="$CONT" MOCK_NO_CONTAINER=1 MOCK_MODE=normal "$RUNNER" --only 's_host' >"$OUT" 2>&1
got=$?
# 종료 코드 1, 컨테이너 폴더 없음 문구, 그리고 결과 줄(has_failed_result: 러너가 끝까지 실행됐는지)을 모두 확인한다.
if [[ $got -eq 1 ]] && grep -qF "컨테이너 폴더를 찾지 못함" "$OUT" && has_failed_result; then
    echo "  PASS  컨테이너 폴더가 없으면 host.sh 를 실행하지 않고 FAIL"
else
    echo "  FAIL  컨테이너 폴더가 없는 경우를 잡지 못함 (종료 코드 $got, 문구나 \"결과: FAILED\" 줄이 없을 수 있음)"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi
rm -rf "$SCEN/s_host"
echo

echo "[런타임 검사 (runtime.json: 종료 코드, cgroup 소멸, 맵 항목 소멸)]"
# 임시 시나리오 s_rt 를 만든다. run.sh 에 trigger 가 있어서 mock 이 s99 로그를 쓰고, 기대(expect.json)도 s99 것을 쓴다.
# 그래서 판정(judge)은 통과하고, 결과는 런타임 검사만으로 갈린다. 인자 $1 = runtime.json 의 내용
make_rt_scn() {
    # 이전 케이스가 남긴 폴더를 지우고 새로 만든다
    rm -rf "$SCEN/s_rt"
    mkdir -p "$SCEN/s_rt"
    # 컨테이너 안에서 실행할 스크립트 (mock 은 내용 중 trigger 만 본다)
    echo '/tmp/trigger; sleep 30' > "$SCEN/s_rt/run.sh"
    # 판정 기대는 s99 와 같다
    cp "$ROOT/scenarios/s99_dummy_block/expect.json" "$SCEN/s_rt/expect.json"
    # 런타임 기대
    printf '%s\n' "$1" > "$SCEN/s_rt/runtime.json"
}
# 이 묶음은 s_rt 하나만 실행한다
RUNNER_ARGS=(--only s_rt)
# 모든 케이스에 공통인 환경: 가짜 cgroup 루트, 가짜 bpftool, cgroup_id 400261 (가짜 bpftool 의 present 항목과 같은 값)
RT_ENV=(MYC_CHECK_CGROUP_ROOT="$CGR" MYC_BPFTOOL="$HERE/mock/bpftool" MOCK_CGROUP_ID=400261)
make_rt_scn '{"exit_code":137,"cgroup_gone":true,"map_entry_gone":true}'
# 1: 세션이 죽었고, cgroup 이 없고, 맵 항목도 없다 -> 통과
check "rt1 killed, cgroup 없음, 맵 항목 없음 -> 통과" 0 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_MAP=absent
# 2: 세션이 죽지 않았다 (mock normal 은 종료 코드 0, meta.json 없음)
check "rt2 종료 코드 0 (죽지 않음) -> FAIL" 1 "${RT_ENV[@]}" MOCK_MODE=normal MOCK_MAP=absent
expect_text "rt2 137 아님을 알림" "137 아님"
# 3: 종료 코드는 137 인데 meta.json 의 exit_code 가 없거나 다르다
check "rt3a meta.json 에 exit_code 없음 -> FAIL" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_META=missing MOCK_MAP=absent
expect_text "rt3a 이유를 알림" "meta.json 에 exit_code 가 없음"
check "rt3b meta.json 의 exit_code 가 다름 -> FAIL" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_META=wrong MOCK_MAP=absent
expect_text "rt3b 이유를 알림" "meta.json 의 exit_code 0 가 agent-run 종료 코드 137 와 다름"
# 4: cgroup 디렉토리가 남았다 (rmdir 실패 흉내)
check "rt4 cgroup 디렉토리가 남음 -> FAIL" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_CG_LEFT=1 MOCK_MAP=absent
expect_text "rt4 이유를 알림" "cgroup 디렉토리가 남아 있음"
# 남긴 가짜 cgroup 디렉토리를 치운다 (다음 케이스에 영향이 없게)
rm -rf "${CGR:?}"/mycontainer-*
# 5: 맵 항목이 끝까지 남았다 -> 재시도를 다 쓰고 FAIL
check "rt5 맵 항목이 끝까지 남음 -> FAIL" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_MAP=present
expect_text "rt5 이유를 알림" "session_cgroups 에 cgroup_id 400261 항목이 남아 있음"
# 6: 맵 항목이 3번 확인할 동안 남아 있다가 사라진다 (재시도 범위 안) -> 통과
: >"$MAPCOUNT"
check "rt6 맵 항목이 늦게 사라짐 (재시도 안) -> 통과" 0 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_MAP=late MOCK_MAP_LATE_N=3 MOCK_MAP_COUNT="$MAPCOUNT"
# 7: bpftool 이 실패하거나 출력이 JSON 이 아니면 건너뛰지 않고 FAIL
check "rt7a bpftool 오류 -> FAIL (SKIP 아님)" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_MAP=error
expect_text "rt7a 이유를 알림" "bpftool 실패"
check "rt7b bpftool 출력이 JSON 아님 -> FAIL (SKIP 아님)" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_MAP=invalid_json
expect_text "rt7b 이유를 알림" "bpftool 출력을 해석하지 못함"
# 10: agent-run 출력에서 cgroup_id 를 뽑지 못함 -> FAIL
check "rt10 cgroup_id 를 못 뽑음 -> FAIL" 1 "${RT_ENV[@]}" MOCK_MODE=killed MOCK_MAP=absent MOCK_CGROUP_ID=abc
expect_text "rt10 이유를 알림" "cgroup_id 를 얻지 못함"
# 8: map_entry_gone 이 있는데 bpftool 을 찾을 수 없음 -> 사전 점검에서 시작 거부 (종료 코드 2)
check "rt8 bpftool 이 없음 -> 시작 거부" 2 "${RT_ENV[@]}" MYC_BPFTOOL=myc-no-such-bpftool MOCK_MODE=killed
expect_text "rt8 이유를 알림" "map_entry_gone 검사에 bpftool 이 필요하다"
# 9: runtime.json 이 틀렸다 -> 사전 점검에서 시작 거부 (오타로 검사가 조용히 빠지는 것을 막는다)
make_rt_scn '{"exit_code":137,"cgroup_gon":true}'
check "rt9a runtime.json 에 알 수 없는 키 -> 시작 거부" 2 "${RT_ENV[@]}" MOCK_MODE=killed
expect_text "rt9a 이유를 알림" "runtime.json 형식 오류"
make_rt_scn '{"exit_code":137,'
check "rt9b runtime.json 이 깨진 JSON -> 시작 거부" 2 "${RT_ENV[@]}" MOCK_MODE=killed
make_rt_scn '{"exit_code":"137"}'
check "rt9c runtime.json 의 타입 오류 (exit_code 가 문자열) -> 시작 거부" 2 "${RT_ENV[@]}" MOCK_MODE=killed
make_rt_scn '{"map_entry_gone":"yes"}'
check "rt9d runtime.json 의 타입 오류 (map_entry_gone 이 문자열) -> 시작 거부" 2 "${RT_ENV[@]}" MOCK_MODE=killed
# 정리: 임시 시나리오를 지우고 추가 인자를 비운다 (아래 케이스들은 기존대로 전체 시나리오를 돈다)
rm -rf "$SCEN/s_rt"
RUNNER_ARGS=()
echo

echo "[시작을 거부하는가 (종료 코드 2)]"
check "로더가 준비되지 못하면 시작하지 않음" 2 MOCK_MODE=noready
expect_text "로더 출력을 보여 줌" "BPF 로드 실패"
echo

echo "[로더 옵션과 ready 줄 (--detectors, mode)]"
# 가짜 로더가 기록한 PID 의 프로세스가 끝났는지 확인한다. 러너가 끝난 뒤에도 살아 있으면 정리되지 않은 것이다
expect_loader_gone() {
    # 확인 내용 설명
    local msg="$1" pid
    # 기록 파일의 "pid=<번호>" 줄에서 번호만 꺼낸다
    pid="$(sed -n 's/^pid=//p' "$LREC")"
    # 번호가 있고, kill -0 (살아 있는지 확인만) 이 실패해야 통과
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        printf '  PASS  %s\n' "$msg"
    else
        # 번호가 없거나 아직 살아 있다
        printf '  FAIL  %s (로더 pid=%s 가 살아 있거나 기록이 없음)\n' "$msg" "${pid:-없음}"
        failures=$((failures + 1))
    fi
}
# 기록 파일에 정확히 그 줄이 있는지 확인한다 (러너가 로더에 넘긴 인자)
expect_loader_arg() {
    # 설명과 찾을 줄
    local msg="$1" line="$2"
    # -x : 줄 전체가 같아야 한다, -F : 글자 그대로
    if grep -qxF -- "$line" "$LREC"; then
        printf '  PASS  %s\n' "$msg"
    else
        # 기록 파일 내용을 보여 준다
        printf '  FAIL  %s ("%s" 줄이 없음)\n' "$msg" "$line"
        sed 's/^/        /' "$LREC"
        failures=$((failures + 1))
    fi
}
# ld1: 정상. 러너가 --detectors 로 세 탐지기를 넘기고, ready 줄이 맞으면 그대로 돈다
: >"$LREC"
check "ld1 ready 줄의 mode 와 detectors 가 맞으면 통과" 0 MOCK_MODE=normal MOCK_LOADER_RECORD="$LREC"
# 러너는 RUNNER_DETECTORS 를 정렬하지 않고 그대로 넘긴다 (정렬은 ready 비교에서만)
expect_loader_arg "ld1 러너가 --detectors 로 세 탐지기를 넘김" "--detectors=write_exec_boundary,dummy_block,dummy_suspect"
expect_loader_gone "ld1 끝나면 로더가 정리됨"
# ld2: 옛 형식 ready (mode, detectors 없음) -> 시작 거부
: >"$LREC"
check "ld2 옛 형식 ready 줄 -> 시작 거부" 2 MOCK_MODE=oldready MOCK_LOADER_RECORD="$LREC"
expect_text "ld2 이유를 알림" "ready 줄이 기대와 다르다"
expect_loader_gone "ld2 거부한 뒤 로더가 정리됨"
# ld3: 켜진 탐지기가 다름 (dummy_suspect 가 빠짐) -> 시작 거부
: >"$LREC"
check "ld3 detectors 가 다르면 시작 거부" 2 MOCK_MODE=normal MOCK_READY_DETECTORS=dummy_block,write_exec_boundary MOCK_LOADER_RECORD="$LREC"
expect_text "ld3 기대 목록을 알림" "기대: mode: kill, detectors: dummy_block,dummy_suspect,write_exec_boundary"
expect_loader_gone "ld3 거부한 뒤 로더가 정리됨"
# ld4: 목록은 같지만 알파벳순이 아님 (러너가 넘긴 순서 그대로) -> 시작 거부 (로더는 항상 정렬해서 낸다)
: >"$LREC"
check "ld4 detectors 순서가 알파벳순이 아니면 시작 거부" 2 MOCK_MODE=normal MOCK_READY_DETECTORS=write_exec_boundary,dummy_block,dummy_suspect MOCK_LOADER_RECORD="$LREC"
# ld5: mode 가 kill 이 아님 -> 시작 거부
: >"$LREC"
check "ld5 mode 가 kill 이 아니면 시작 거부" 2 MOCK_MODE=normal MOCK_READY_MODE=observe MOCK_LOADER_RECORD="$LREC"
expect_text "ld5 실제 mode 를 알림" "실제: mode: 'observe'"
expect_loader_gone "ld5 거부한 뒤 로더가 정리됨"

# --only 옵션: 이름이 맞는 시나리오만
# 아래 세 묶음은 check 함수를 쓰지 않고 풀어 쓴 것이다 (옵션을 직접 넘기거나 확인 조건이 달라서).
# 구조는 같다: 실행 -> got=$? -> 조건 확인 -> PASS/FAIL 출력.
# --only 's99*' : 따옴표로 감싸서, 쉘이 s99* 를 파일 이름으로 펼치지 않고 러너에 글자 그대로 넘긴다.
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MOCK_MODE=normal "$RUNNER" --only 's99*' >"$OUT" 2>&1
got=$?
# 두 조건을 && 로 잇는다. 종료 코드가 0 이고 (-eq 는 숫자 비교), 출력에 "시나리오 1/1 통과" 가 있어야 한다.
if [[ $got -eq 0 ]] && grep -qF "시나리오 1/1 통과" "$OUT"; then
    echo "  PASS  --only 's99*' 는 s99 하나만 실행"
else
    # 한 줄에 여러 명령을 ; 로 잇는다. 실패하면 러너 출력을 보여 주고 failures 를 1 늘린다.
    echo "  FAIL  --only 's99*' 동작 이상"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi
# 이름과 맞는 시나리오가 없는 패턴('zzz*')이면 러너는 종료 코드 2 로 끝나야 한다 ("통과"처럼 보이면 안 된다).
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MYC_SCEN_DIR="$SCEN" MOCK_MODE=normal "$RUNNER" --only 'zzz*' >"$OUT" 2>&1
got=$?
if [[ $got -eq 2 ]]; then
    echo "  PASS  맞는 시나리오가 없으면 종료 코드 2"
else
    echo "  FAIL  맞는 시나리오가 없는데 종료 코드 $got"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi

# 사전 점검: 필수 파일이 없으면 시작하지 않아야 한다
# 존재하지 않는 경로를 MYC_SRC_DIR 로 주면 preflight 가 "[preflight]" 메시지와 함께 종료 코드 2 로 멈춰야 한다.
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="/없는/경로" "$RUNNER" >"$OUT" 2>&1
got=$?
if [[ $got -eq 2 ]] && grep -qF "[preflight]" "$OUT"; then
    echo "  PASS  빌드 결과물이 없으면 사전 점검에서 멈춤 (종료 코드 2)"
else
    echo "  FAIL  사전 점검이 동작하지 않음 (종료 코드 $got)"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi

echo "[임시 폴더 정리]"
# 결과를 PASS/FAIL 한 줄로 내는 작은 도우미. ok 가 0 이면 PASS
tmp_result() {
    # 설명, 조건 결과(0 이면 참), 실패 때 덧붙일 내용
    local msg="$1" ok="$2" extra="${3-}"
    if [[ "$ok" -eq 0 ]]; then
        printf '  PASS  %s\n' "$msg"
    else
        printf '  FAIL  %s %s\n' "$msg" "$extra"
        failures=$((failures + 1))
    fi
}
# tc1: 이 스크립트를 자체 점검 모드로 한 번 실행한다 (러너 1회 실패 -> 작업 폴더가 남음 -> 끝날 때 trap 이 전용 폴더를 지움)
st_out="$(env MYC_TR_SELFTEST=1 bash "$HERE/test_runner.sh" 2>&1)"
# 자식이 알려 준 전용 폴더와 보관 폴더
st_dir="$(sed -n 's/^selftest-dir=//p' <<<"$st_out")"
st_kept="$(sed -n 's/^selftest-kept=//p' <<<"$st_out")"
# 정리 직전에 전용 폴더와 작업 폴더가 실제로 있었는가 (비어서 통과하는 것 방지)
grep -qx 'selftest-dir-exists=1' <<<"$st_out" && grep -qx 'selftest-kept-exists=1' <<<"$st_out"
tmp_result "tc1 정리 직전에 전용 폴더와 러너 작업 폴더가 실제로 있었음" $? "(자식 출력: $st_out)"
# 러너 작업 폴더가 /tmp 바로 밑이 아니라 전용 폴더 안에 만들어졌는가 (${st_kept%/*} 는 마지막 / 앞까지 = 상위 폴더)
[[ -n "$st_dir" && "${st_kept%/*}" == "$st_dir" && "${st_kept##*/}" == myc_scen.* ]]
tmp_result "tc1 러너 작업 폴더가 전용 폴더 안에 생김 (밖에 남지 않음)" $? "(전용: '$st_dir', 작업: '$st_kept')"
# 자식이 끝난 뒤 전용 폴더가 통째로 없어졌는가 (그 안의 작업 폴더도 함께)
[[ -n "$st_dir" && ! -e "$st_dir" && ! -e "$st_kept" ]]
tmp_result "tc1 끝나면 전용 폴더와 그 안의 작업 폴더가 지워짐" $? "(남은 것: $(ls -d "$st_dir" "$st_kept" 2>/dev/null | tr '\n' ' '))"
# 정리를 거부한 메시지가 없어야 한다
! grep -qF "정리 거부" <<<"$st_out"
tmp_result "tc1 정리 거부 메시지 없음" $? "(자식 출력: $st_out)"
# tc2: 안전장치. 지우면 안 되는 대상은 거부(1)하고 이유를 알려야 한다. 출력은 errf 에 모은다
errf="$SCENTMP/tc2.err"
remove_scen_tmp "" 2>"$errf"; rc=$?
[[ $rc -eq 1 ]] && grep -qF "변수가 비었음" "$errf"
tmp_result "tc2 빈 변수면 지우지 않고 거부" $? "(rc=$rc, $(cat "$errf"))"
remove_scen_tmp "/" 2>"$errf"; rc=$?
[[ $rc -eq 1 ]] && grep -qF "/ 는 지우지 않음" "$errf"
tmp_result "tc2 / 이면 지우지 않고 거부" $? "(rc=$rc, $(cat "$errf"))"
# 이름은 mktemp 형태지만 이 실행이 만든 폴더가 아닌 것 (전용 폴더 안에 만든 미끼)
decoy="$SCENTMP/myc_trtmp.Decoy1"
mkdir "$decoy"
remove_scen_tmp "$decoy" 2>"$errf"; rc=$?
[[ $rc -eq 1 && -d "$decoy" ]] && grep -qF "만든 폴더가 아님" "$errf"
tmp_result "tc2 다른 폴더(이름이 비슷해도)는 지우지 않음" $? "(rc=$rc, $(cat "$errf"))"
# 전용 폴더의 상위 폴더 (한 단계 위를 지우려는 실수)
remove_scen_tmp "${SCENTMP%/*}" 2>"$errf"; rc=$?
[[ $rc -eq 1 && -d "${SCENTMP%/*}" ]]
tmp_result "tc2 상위 폴더는 지우지 않음" $? "(rc=$rc, $(cat "$errf"))"

# tc3: 작업 폴더의 상위(MYC_SCEN_TMP)가 없는 폴더면 러너는 mktemp 실패를 알아채고 2 로 멈춰야 한다.
# 멈추지 않으면 WORK 가 비어 SESS_ROOT 가 /sessions 가 되고 / 바로 밑에 폴더를 만들려 한다.
# 없는 폴더는 전용 폴더 안의 이름으로 정한다 (만들지 않는다)
missing_tmp="$SCENTMP/no_such_dir"
# /sessions 가 이미 있으면 "생기지 않았다"를 판단할 수 없으므로 실행 전에 기록해 둔다
pre_sessions=0; [[ -e /sessions ]] && pre_sessions=1
# check 의 환경변수 인자로 주면 이 한 번의 실행에만 MYC_SCEN_TMP 가 바뀐다 (export 된 값은 그대로)
check "tc3 작업 폴더를 만들지 못하면 시작 거부" 2 MOCK_MODE=normal MYC_SCEN_TMP="$missing_tmp"
expect_text "tc3 이유를 알림" "[runner] 작업 폴더를 만들지 못함"
# 작업 폴더 없이 다음 단계로 가지 않았어야 한다. 갔다면 / 바로 밑(/sessions, /loader.out)을 쓰려다 실패하거나 로더를 띄운다.
# root 가 아니면 mkdir 이 경로 없이 "Permission denied" 만 찍고 폴더도 안 생기므로, 경로 대신 이런 흔적을 본다
! grep -qE "Permission denied|\[loader\]|(^|[ '\"(:])/(sessions|loader\.)" "$OUT"
tmp_result "tc3 작업 폴더 없이 다음 단계(/ 밑에 쓰기, 로더 시작)로 가지 않음 (출력)" $? "(출력: $(tr '\n' ' ' <"$OUT"))"
# /sessions 가 실제로 생기지 않았어야 한다 (실행 전에 이미 있었으면 판단할 수 없으므로 실패로 알린다)
[[ $pre_sessions -eq 0 && ! -e /sessions ]]
tmp_result "tc3 /sessions 가 생기지 않음" $? "(실행 전부터 있었음=$pre_sessions)"
# 다음 케이스들에 영향이 없는지: export 된 값이 전용 폴더 그대로인가
[[ "$MYC_SCEN_TMP" == "$SCENTMP" ]]
tmp_result "tc3 다른 케이스의 MYC_SCEN_TMP 는 그대로" $? "(지금 값: $MYC_SCEN_TMP)"

echo
# 마지막: 실패한 케이스가 없으면 종료 코드 0, 있으면 1.
if [[ $failures -eq 0 ]]; then
    echo "ALL PASSED (실패 0)"
    exit 0
fi
echo "FAILED (실패 $failures)"
exit 1
