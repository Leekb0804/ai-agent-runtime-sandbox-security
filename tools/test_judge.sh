#!/bin/bash
#
# tools/test_judge.sh
#
# ===== 이 파일의 역할 =====
# 판정기(judge.sh)가 "통과해야 할 때 통과하고, 실패해야 할 때 실패하는가"를 검증하는 단위 테스트.
# 커널, 컨테이너, root 권한이 필요 없다. fixtures/ 의 로그 파일을 입력으로 쓴다.
#
# fixtures/real_* 는 4일차에 실제로 agent-run 과 로더를 돌려서 얻은 세션 폴더(events.jsonl, verdicts.jsonl)이다.
# fixtures/bad_* 는 그것을 일부러 깨뜨린 것이고, empty 는 빈 로그, events_only 는 판정이 0줄인 로그이다.
#
# ===== 왜 필요한가 =====
# 항상 PASS 하는 테스트는 아무것도 검증하지 못한다. 러너가 어떤 시나리오를 FAIL 로 판정할 수 있다는 것을
# 먼저 이 테스트로 증명해 두어야, 나중에 시나리오가 PASS 했을 때 그 PASS 를 믿을 수 있다.
#
# 사용법: tools/test_judge.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 이 파일의 구조: check 함수를 정의하고, 케이스마다 check 를 한 줄씩 호출한다.
# 문법은 tools/judge.sh 와 run_scenarios.sh 의 주석을 참고한다.
# set -u : 값이 정해지지 않은 변수를 쓰면 오류로 멈춘다.
set -u
# 이 스크립트가 있는 폴더(tools)의 절대 경로. 구하는 방법은 run_scenarios.sh 의 같은 줄 설명 참고.
HERE="$(cd "$(dirname "$0")" && pwd)"
# 한 단계 위 폴더 = 저장소 루트.
ROOT="$(cd "$HERE/.." && pwd)"
# 검사 대상(판정기)과 입력 파일들의 경로.
JUDGE="$HERE/judge.sh"
FIX="$HERE/fixtures"
S00="$ROOT/scenarios/s00_benign/expect.json"
S99="$ROOT/scenarios/s99_dummy_block/expect.json"

# 실패한 케이스 수를 센다.
failures=0
# mktemp -d : 임시 폴더. 테스트가 만드는 임시 파일(출력, 기대 파일)을 여기에 모은다.
TMP="$(mktemp -d)"
# trap '명령' EXIT : 스크립트가 어떻게 끝나든 마지막에 그 명령을 실행한다. 여기서는 임시 폴더를 지운다.
trap 'rm -rf "$TMP"' EXIT

# 판정기를 실행하고 종료 코드가 기대와 같은지 확인한다.
#   check "<설명>" <기대 종료 코드> <로그> <expect.json>
check() {
    # local : 이 함수 안에서만 쓰는 변수. $1 ~ $4 는 함수에 준 인자이다 (check "설명" 기대코드 로그 expect 파일 순서).
    # 마지막의 got 은 값 없이 선언만 해 둔 것이다.
    local msg="$1" want="$2" log="$3" exp="$4" got
    # 판정기를 실행하되 출력은 파일로 돌린다 (>out.txt 는 표준 출력, 2>err.txt 는 오류 출력).
    # 이 테스트가 보려는 것은 출력이 아니라 종료 코드이다.
    "$JUDGE" "$log" "$exp" >"$TMP/out.txt" 2>"$TMP/err.txt"
    # $? : 바로 앞 명령(판정기)의 종료 코드. 다른 명령을 실행하면 바뀌므로 바로 저장한다.
    got=$?
    # 종료 코드가 기대와 같은지 비교한다 (문자열 비교).
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$msg"
    else
        printf '  FAIL  %s (기대 종료 코드 %s, 실제 %s)\n' "$msg" "$want" "$got"
        # sed 's/^/        /' 파일들 : 각 줄 앞에 공백 8칸을 붙여 들여쓰기해서, 실패한 케이스의 판정기 출력을 그대로 보여 준다.
        sed 's/^/        /' "$TMP/out.txt" "$TMP/err.txt"
        # $(( )) 는 계산이다. 실패 수를 하나 늘린다.
        failures=$((failures + 1))
    fi
}

# 로그 파일 하나만 읽는 모드를 위한 기대 파일 (verdicts.jsonl 만으로 확인 가능한 내용)
# cat >파일 <<'EOF2' ... EOF2 : "여기 문서(heredoc)". EOF2 라고만 쓴 줄이 나올 때까지의 내용을 파일에 쓴다.
# 'EOF2' 처럼 따옴표를 붙이면 내용 안의 $ 같은 글자를 쉘이 해석하지 않고 그대로 쓴다.
# 시작과 끝에 쓰는 이름(EOF2)은 같기만 하면 아무 이름이어도 된다.
cat >"$TMP/verdict_only.json" <<'EOF2'
{ "expect": [ { "match": { "type": "verdict", "level": "BLOCK", "detector": "dummy_block" }, "count": 1 } ] }
EOF2

# 각 묶음의 제목을 출력하고, 그 아래의 check 호출들이 그 묶음에 속한다.
# check 인자 순서: 설명, 기대 종료 코드 (0 통과 / 1 검사 실패 / 2 입력 오류), 로그, expect.json.
echo "[통과해야 하는 경우: 실제 로그 + 맞는 기대값]"
check "s00_benign: 무해한 명령은 차단 없이 기록됨" 0 "$FIX/real_s00_benign"     "$S00"
check "s99_dummy_block: BLOCK 1개, would_kill 1번, 이후 기록 계속" 0 "$FIX/real_s99_dummy_block" "$S99"

echo "[탐지기와 무관한가: 판정이 0줄이어도 무해한 시나리오는 통과]"
check "탐지기가 하나도 없어도(판정 0줄) s00 은 통과 (이벤트 관측만 본다)" 0 "$FIX/events_only" "$S00"
check "같은 로그를 s99 와 비교하면 실패 (BLOCK 판정이 없으므로)" 1 "$FIX/events_only" "$S99"

echo "[실패해야 하는 경우: 실제 로그 + 틀린 기대값]"
check "차단이 있는 로그를 s00(차단 없어야 함)과 비교하면 실패" 1 "$FIX/real_s99_dummy_block" "$S00"
check "차단 없는 로그를 s99(차단 있어야 함)와 비교하면 실패"   1 "$FIX/real_s00_benign"     "$S99"

echo "[실패해야 하는 경우: 로그를 일부러 깨뜨림]"
check "BLOCK 은 있는데 종료 요청 기록이 빠지면 실패"          1 "$FIX/bad_no_action"     "$S99"
check "종료 요청이 두 번 기록되면 실패 (멱등성 위반)"          1 "$FIX/bad_double_action" "$S99"

echo "[가짜 통과 방지: 빈 로그]"
check "빈 로그는 s00 의 양성 검사 때문에 실패" 1 "$FIX/empty" "$S00"
# 존재하지 않는 폴더를 일부러 넘긴다 (경로가 한글이라 오타처럼 보이지만 의도적이다).
# 판정기는 없는 로그를 "빈 로그"로 취급하고 양성 검사가 실패해야 한다.
check "존재하지 않는 세션 폴더도 실패"          1 "$FIX/없는폴더" "$S00"

echo "[입력 형식]"
# 폴더가 아니라 파일 하나를 넘기는 경우 (judge.sh 의 "파일 모드").
check "로그 파일 하나만 넘겨도 읽는다 (단위 테스트용 호환)" 0 "$FIX/real_s99_dummy_block/verdicts.jsonl" "$TMP/verdict_only.json"

echo "[입력 오류는 실패(1)가 아니라 오류(2)로 구분]"
# fixtures/bad_corrupt 는 일부러 JSON 이 깨진 줄을 넣은 로그이다. 이런 입력은 "검사 실패(1)"가 아니라 "입력 오류(2)"여야 한다.
check "깨진 JSON 로그는 입력 오류" 2 "$FIX/bad_corrupt" "$S00"

# 음성 검사만 있는 기대 파일은 거부해야 한다
# 위와 같은 heredoc 이다. 이름만 EOF 로 다르다.
cat >"$TMP/negative_only.json" <<'EOF'
{ "expect": [ { "match": { "type": "verdict", "level": "BLOCK" }, "count": 0 } ] }
EOF
# 입력 오류(2)는 로그를 읽기 전에 expect 파일 검증에서 먼저 나므로, 이 케이스들의 로그 경로는 존재하지 않아도 된다
# (아래 몇 줄의 .jsonl 경로도 마찬가지이다). 확인하려는 것은 expect.json 의 형식 검증이다.
check "음성 검사만 있는 expect.json 은 입력 오류 (빈 로그로도 통과하므로)" 2 "$FIX/empty.jsonl" "$TMP/negative_only.json"

# 한 줄짜리 파일은 heredoc 대신 echo 로 만들 수 있다. '...' 안의 JSON 은 쉘이 건드리지 않는다.
echo '{ "expect": [] }' >"$TMP/empty_expect.json"
check "비어 있는 expect 배열은 입력 오류" 2 "$FIX/real_s00_benign.jsonl" "$TMP/empty_expect.json"

echo '{ "expect": [ { "count": 1 } ] }' >"$TMP/no_match.json"
check "match 가 없는 검사는 입력 오류" 2 "$FIX/real_s00_benign.jsonl" "$TMP/no_match.json"

check "expect 파일이 없으면 입력 오류" 2 "$FIX/real_s00_benign.jsonl" "$TMP/없는기대.json"

echo
# 마지막: 실패한 케이스가 없으면 종료 코드 0, 있으면 1.
if [[ $failures -eq 0 ]]; then
    echo "ALL PASSED (실패 0)"
    exit 0
fi
echo "FAILED (실패 $failures)"
exit 1
