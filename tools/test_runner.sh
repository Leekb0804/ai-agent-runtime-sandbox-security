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

failures=0
# mktemp : 임시 "파일"을 만들고 경로를 출력한다 (-d 를 붙이면 폴더). 러너의 출력을 여기에 모아 두고 검사한다.
OUT="$(mktemp)"
# trap '명령' EXIT : 스크립트가 어떻게 끝나든 마지막에 그 명령을 실행한다. 여기서는 임시 파일을 지운다.
trap 'rm -f "$OUT"' EXIT

# 가짜 구현으로 러너를 실행하고 종료 코드를 확인한다.
#   check "<설명>" <기대 종료 코드> [환경변수=값 ...]
# 러너 출력에 반드시 들어 있어야 하는 문구는 직후에 expect_text 로 확인한다.
check() {
    local msg="$1" want="$2" got
    # shift 2 : 앞의 두 인자(설명, 기대 코드)를 버리고 나머지를 앞으로 당긴다.
    # 남은 인자($@)는 MOCK_MODE=normal 같은 "환경변수=값" 들이다.
    shift 2
    # env 변수=값 ... 명령 : 그 환경변수들을 지정해서 명령을 실행한다. "$@" 는 남은 인자 전체이다.
    # 즉 이 줄은 MYC_RUNNER_TEST=1 MYC_SRC_DIR=tools/mock MOCK_MODE=... ./run_scenarios.sh 와 같다.
    # 출력과 오류 출력은 모두 OUT 파일에 모은다 (>"$OUT" 2>&1). 바로 다음 줄에서 종료 코드를 got 에 저장한다.
    env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" "$@" "$RUNNER" >"$OUT" 2>&1
    got=$?
    # 러너의 종료 코드가 기대와 같은지 비교한다.
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$msg"
    else
        printf '  FAIL  %s (기대 종료 코드 %s, 실제 %s)\n' "$msg" "$want" "$got"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
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

# check 는 가짜 구현(MYC_RUNNER_TEST=1 과 MYC_SRC_DIR=tools/mock 은 자동으로 붙는다)에 MOCK_MODE 를 바꿔 가며 러너를 실행한다.
# MOCK_MODE 의 뜻은 tools/mock/run_container.sh 의 머리 주석 참고.
echo "[정상 흐름]"
check "가짜 로그가 기대와 맞으면 전체 통과 (종료 코드 0)" 0 MOCK_MODE=normal
expect_text "요약에 2개 모두 통과로 표시" "시나리오 2/2 통과"
expect_text "인프라 검증도 통과" "로그 유실 없음"

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

echo "[기다리는가]"
# slow 모드의 가짜 agent-run 은 바로 종료하고 로그는 그 뒤에도 0.3초 간격으로 계속 써진다.
# 러너가 그 도중에 읽지 않고 줄 수가 안정될 때까지 기다려야 통과한다 (wait_settled 가 하는 일).
check "로그가 늦게(0.3초 간격) 써져도 다 쓸 때까지 기다려서 통과" 0 MOCK_MODE=slow

echo "[시작을 거부하는가 (종료 코드 2)]"
check "로더가 준비되지 못하면 시작하지 않음" 2 MOCK_MODE=noready
expect_text "로더 출력을 보여 줌" "BPF 로드 실패"

# --only 옵션: 이름이 맞는 시나리오만
# 아래 세 묶음은 check 함수를 쓰지 않고 풀어 쓴 것이다 (옵션을 직접 넘기거나 확인 조건이 달라서).
# 구조는 같다: 실행 -> got=$? -> 조건 확인 -> PASS/FAIL 출력.
# --only 's99*' : 따옴표로 감싸서, 쉘이 s99* 를 파일 이름으로 펼치지 않고 러너에 글자 그대로 넘긴다.
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MOCK_MODE=normal "$RUNNER" --only 's99*' >"$OUT" 2>&1
got=$?
# 두 조건을 && 로 잇는다. 종료 코드가 0 이고 (-eq 는 숫자 비교), 출력에 "시나리오 1/1 통과" 가 있어야 한다.
if [[ $got -eq 0 ]] && grep -qF "시나리오 1/1 통과" "$OUT"; then
    echo "  PASS  --only 's99*' 는 s99 하나만 실행"
else
    # 한 줄에 여러 명령을 ; 로 잇는다. 실패하면 러너 출력을 보여 주고 failures 를 1 늘린다.
    echo "  FAIL  --only 's99*' 동작 이상"; sed 's/^/        /' "$OUT"; failures=$((failures + 1))
fi
# 이름과 맞는 시나리오가 없는 패턴('zzz*')이면 러너는 종료 코드 2 로 끝나야 한다 ("통과"처럼 보이면 안 된다).
env MYC_RUNNER_TEST=1 MYC_SRC_DIR="$HERE/mock" MOCK_MODE=normal "$RUNNER" --only 'zzz*' >"$OUT" 2>&1
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

echo
# 마지막: 실패한 케이스가 없으면 종료 코드 0, 있으면 1.
if [[ $failures -eq 0 ]]; then
    echo "ALL PASSED (실패 0)"
    exit 0
fi
echo "FAILED (실패 $failures)"
exit 1
