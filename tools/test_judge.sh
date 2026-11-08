#!/bin/bash
#
# tools/test_judge.sh
#
# ===== 이 파일의 역할 =====
# 판정기(judge.sh)가 "통과해야 할 때 통과하고, 실패해야 할 때 실패하는가"를 검증하는 단위 테스트.
# 커널, 컨테이너, root 권한이 필요 없다. fixtures/ 의 로그 파일을 입력으로 쓴다.
#
# fixtures/real_* 는 4일차에 실제로 agent-run 과 로더를 돌려서 얻은 세션 폴더(events.jsonl, verdicts.jsonl)이다.
# fixtures/real_w5_* 는 w5d1 VM 에서 러너가 만든 세션 폴더(events.jsonl, verdicts.jsonl, meta.json)를 그대로 복사한 것이다.
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
S02="$ROOT/scenarios/s02_write_exec_same_session/expect.json"
# 아래 넷은 "탐지기 판정이 없으면 시나리오 기대가 FAIL" 묶음에서 쓴다. s04 기대값
S04="$ROOT/scenarios/s04_write_exec_live/expect.json"
# s08 기대값
S08="$ROOT/scenarios/s08_symlink_disguise/expect.json"
# n03 기대값
N03="$ROOT/scenarios/n03_pip_install_local/expect.json"
# n06 기대값
N06="$ROOT/scenarios/n06_host_runs_output/expect.json"

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

# 바로 앞 check 의 판정기 출력($TMP/out.txt)에 문구가 있는지 확인한다 (tools/test_report.sh 의 expect_text 와 같은 형식)
# 종료 코드만으로는 어느 검사 항목이 FAIL 했는지 알 수 없다. 판정을 지운 탐지기의 항목이 실제로 FAIL 했는지 보려고 쓴다.
#   expect_out "<설명>" "<문구>"
expect_out() {
    # 설명과 문구
    local msg="$1" text="$2"
    # 있으면 통과 (-F: 문구를 정규식이 아니라 글자 그대로 찾는다)
    if grep -qF -- "$text" "$TMP/out.txt"; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 찾던 문구
        printf '  FAIL  %s (출력에 "%s" 가 없음)\n' "$msg" "$text"
        # 판정기 출력을 들여써서 보여 준다
        sed 's/^/        /' "$TMP/out.txt" "$TMP/err.txt"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 세션 폴더에서 탐지기 하나의 판정을 지운 사본을 만든다.
#   strip_detector <원본 세션 폴더> <탐지기 이름> <결과 폴더>
# events.jsonl 은 그대로 복사하고(탐지기와 무관한 관측), verdicts.jsonl 에서 다음 줄만 지운다:
#   - 그 탐지기의 verdict 줄 전부
#   - 그 탐지기 BLOCK verdict 의 reason 과 reason 이 같은 action 줄
# action 줄에는 detector 필드가 없어서 reason 으로 짝짓는다. docs/log-schema-draft.md 의 action 절에 따르면
# action 줄은 세션의 첫 BLOCK verdict 줄 바로 다음 줄에 있고 reason 이 그 verdict 의 reason 과 같다.
# 복사나 jq 가 실패하면 FAIL 줄을 내고 실패 수를 늘린다. 그러지 않으면 비거나 잘린 verdicts.jsonl 때문에
# 뒤의 "실패해야 한다" 검사가 거짓으로 통과할 수 있다.
strip_detector() {
    # 원본 폴더, 탐지기 이름, 결과 폴더
    local src="$1" det="$2" out="$3"
    # 결과 폴더를 만든다 ($TMP 아래)
    mkdir -p "$out"
    # 이벤트 로그는 그대로 복사하고, 판정 로그는 jq 로 걸러 쓴다. 둘 중 하나라도 실패하면 실패로 센다
    if ! cp "$src/events.jsonl" "$out/events.jsonl" \
        || ! jq -c -s --arg d "$det" '([.[] | select(.type == "verdict" and .detector == $d and .level == "BLOCK") | .reason]) as $r | .[] | select(((.type == "verdict" and .detector == $d) or (.type == "action" and (.reason as $x | $r | any(. == $x)))) | not)' "$src/verdicts.jsonl" >"$out/verdicts.jsonl"; then
        # 무엇을 지우다 실패했는지
        printf '  FAIL  판정 지우기 실패: %s 에서 %s\n' "$src" "$det"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# strip_detector 가 만든 폴더의 verdicts.jsonl 에 action 줄이 남지 않았는지 확인한다 (expect_out 과 같은 형식)
# strip_detector 는 탐지기의 BLOCK verdict 에 붙은 action 도 지워야 한다. 지우지 않아도 verdict 항목 때문에
# 지운 검사가 이미 FAIL 하므로, 이 확인이 없으면 action 을 남기는 잘못을 어느 검사도 잡지 못했다.
#   expect_no_action "<설명>" "<결과 폴더>"
expect_no_action() {
    # 설명, 결과 폴더, jq 가 뽑은 action 줄, 그 줄 수
    local msg="$1" dir="$2" lines n
    # action 줄만 뽑는다. jq 가 실패하면(파일 없음, 깨진 줄) 실패로 센다
    if ! lines=$(jq -c 'select(.type == "action")' "$dir/verdicts.jsonl"); then
        # 실패 줄과 읽으려던 파일
        printf '  FAIL  %s (jq 실패: %s/verdicts.jsonl)\n' "$msg" "$dir"
        # 실패 수를 늘린다
        failures=$((failures + 1))
        # 줄 수는 세지 않는다
        return
    fi
    # 뽑은 줄 수를 센다 (grep -c '^' 는 빈 출력이면 0, 마지막 줄에 줄바꿈이 없어도 그 줄을 센다)
    n=$(printf '%s' "$lines" | grep -c '^')
    # 0 이면 통과
    if [[ "$n" == 0 ]]; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 남은 action 줄 수, 폴더
        printf '  FAIL  %s (action 줄 %s개가 남음: %s)\n' "$msg" "$n" "$dir"
        # 실패 수를 늘린다
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
# 주의: real_s99_dummy_block 과 bad_double_action 의 action 줄은 실제 VM 로그가 아니다.
#       4일차 로그의 would_kill 줄을 w3d2 에 새 형식(action=kill, result/detail/errno)으로 손으로 고쳤다.
#       나머지 줄은 4일차 실제 로그 그대로이다. VM 에서 새로 뜬 실제 로그로 교체하는 것은 나중 일이다.
#       (tools/mock/run_container.sh 도 이 fixture 를 복사해서 쓴다)
echo "[통과해야 하는 경우: 실제 로그 + 맞는 기대값]"
check "s00_benign: 무해한 명령은 차단 없이 기록됨" 0 "$FIX/real_s00_benign"     "$S00"
check "s99_dummy_block: BLOCK 1개, 종료 시도(kill, result=sent) 1번, 같은 이벤트의 다른 판정도 남음" 0 "$FIX/real_s99_dummy_block" "$S99"

echo "[탐지기와 무관한가: 판정이 0줄이어도 무해한 시나리오는 통과]"
check "탐지기가 하나도 없어도(판정 0줄) s00 은 통과 (이벤트 관측만 본다)" 0 "$FIX/events_only" "$S00"
check "같은 로그를 s99 와 비교하면 실패 (BLOCK 판정이 없으므로)" 1 "$FIX/events_only" "$S99"

echo "[실패해야 하는 경우: 실제 로그 + 틀린 기대값]"
check "차단이 있는 로그를 s00(차단 없어야 함)과 비교하면 실패" 1 "$FIX/real_s99_dummy_block" "$S00"
check "차단 없는 로그를 s99(차단 있어야 함)와 비교하면 실패"   1 "$FIX/real_s00_benign"     "$S99"

echo "[실패해야 하는 경우: 로그를 일부러 깨뜨림]"
check "BLOCK 은 있는데 종료 요청 기록이 빠지면 실패"          1 "$FIX/bad_no_action"     "$S99"
check "종료 요청이 두 번 기록되면 실패 (멱등성 위반)"          1 "$FIX/bad_double_action" "$S99"

echo "[종료 시도의 result 가 실제로 비교되는가]"
# s99 fixture 에서 result 만 sent -> already_gone 으로 바꾼 로그를 임시 폴더에 만든다.
mkdir -p "$TMP/gone"
cp "$FIX/real_s99_dummy_block/events.jsonl" "$TMP/gone/events.jsonl"
sed 's/"result":"sent"/"result":"already_gone"/' "$FIX/real_s99_dummy_block/verdicts.jsonl" >"$TMP/gone/verdicts.jsonl"
check "기대는 result=sent 인데 로그는 already_gone 이면 실패" 1 "$TMP/gone" "$S99"
# 같은 로그를 result=already_gone 기대로 보면 통과해야 한다 (result 가 비교에서 빠지면 여기서 실패한다)
cat >"$TMP/expect_gone.json" <<'EOF3'
{ "expect": [ { "match": { "type": "action", "action": "kill", "result": "already_gone" }, "count": 1 } ] }
EOF3
check "기대와 로그가 모두 result=already_gone 이면 통과" 0 "$TMP/gone" "$TMP/expect_gone.json"

echo "[음성 검사가 실제 이름으로 세는가: s02 의 action=kill count 0]"
# s02 의 다른 검사(TAG_HIT 관측, write_exec_boundary SUSPECT 1개, BLOCK 0개)는 모두 만족하는 손으로 만든 로그.
# kill 레코드가 없는 쪽은 통과하고, kill 레코드 한 줄만 더한 쪽은 실패해야 한다.
# (기대값의 이름이 로그와 다르면(예: would_kill) kill 레코드를 세지 못해 항상 통과하는 음성 검사가 된다)
mkdir -p "$TMP/s02_ok" "$TMP/s02_kill"
cat >"$TMP/s02_ok/events.jsonl" <<'EOF4'
{"schema_version":0,"type":"event","session":"t-1","logged_at_ms":1,"event":{"kind":"TAG_HIT","pid":10,"cgroup_id":500,"ts_ns":2,"exec_cgroup_id":500,"tag_ts_ns":1,"tag_write_count":1,"dev":40,"ino":7,"filename":"/tmp/payload"}}
EOF4
cat >"$TMP/s02_ok/verdicts.jsonl" <<'EOF4'
{"schema_version":0,"type":"verdict","session":"t-1","logged_at_ms":1,"level":"SUSPECT","detector":"write_exec_boundary","reason":"same session","event":{"kind":"TAG_HIT","pid":10,"cgroup_id":500,"ts_ns":2,"exec_cgroup_id":500,"tag_ts_ns":1,"tag_write_count":1,"dev":40,"ino":7,"filename":"/tmp/payload"}}
EOF4
cp "$TMP/s02_ok/events.jsonl" "$TMP/s02_kill/events.jsonl"
cp "$TMP/s02_ok/verdicts.jsonl" "$TMP/s02_kill/verdicts.jsonl"
echo '{"schema_version":0,"type":"action","session":"t-1","logged_at_ms":1,"cgroup_id":500,"action":"kill","result":"sent","detail":"written","errno":0,"reason":"x"}' >>"$TMP/s02_kill/verdicts.jsonl"
check "s02 기대값: kill 레코드가 없으면 통과" 0 "$TMP/s02_ok" "$S02"
check "s02 기대값: kill 레코드가 하나라도 있으면 실패" 1 "$TMP/s02_kill" "$S02"

echo "[관찰 모드의 would_kill 레코드]"
# judge.sh 는 action 이름을 제한하지 않는다 (flat 이 .action, .result 를 그대로 꺼낸다).
# 관찰 모드 로더가 남기는 would_kill 한 줄(손으로 만든 로그)이 그대로 세지고, action=kill 집계에는 섞이지 않는지 고정한다
mkdir -p "$TMP/observe"
cat >"$TMP/observe/verdicts.jsonl" <<'EOF5'
{"schema_version":0,"type":"action","session":"t-1","logged_at_ms":1,"cgroup_id":500,"action":"would_kill","result":"not_sent","detail":"observe_mode","errno":0,"reason":"x"}
EOF5
# 양성: would_kill/not_sent 정확히 1개. 음성: 같은 로그에서 action=kill 은 0개
cat >"$TMP/expect_observe.json" <<'EOF5'
{ "expect": [
  { "match": { "type": "action", "action": "would_kill", "result": "not_sent" }, "count": 1 },
  { "match": { "type": "action", "action": "kill" }, "count": 0 }
] }
EOF5
check "would_kill 은 그대로 세지고 action=kill 에 섞이지 않음" 0 "$TMP/observe" "$TMP/expect_observe.json"

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

echo "[탐지기 판정이 없으면 시나리오 기대가 FAIL]"
# 시나리오마다 원본 fixture 의 대조(기대 0)를 먼저 보고, 그 탐지기의 판정을 strip_detector 로 지운 로그의 실패(기대 1)를 본다.
# expect_out 이 찾는 문구는 judge.sh 의 FAIL 줄 앞부분(FAIL, 탭, 검사 번호, 탭, match)이다.
# match 만 찾으면 같은 탐지기의 OK 줄(예: s04 의 #6 SUSPECT count 0)에도 걸려 항상 통과하므로 FAIL 과 번호를 붙인다.
# s04 대조: 원본은 통과
check "s04 대조: real_w5_s04 는 s04 기대를 통과" 0 "$FIX/real_w5_s04" "$S04"
# s04 에서 write_exec_boundary 의 판정(BLOCK)과 그 action 을 지운다
strip_detector "$FIX/real_w5_s04" write_exec_boundary "$TMP/strip_s04_write_exec_boundary"
# 지운 로그는 실패
check "s04: write_exec_boundary 판정(BLOCK)과 그 action 을 지우면 실패" 1 "$TMP/strip_s04_write_exec_boundary" "$S04"
# 실패한 항목에 write_exec_boundary 의 BLOCK 검사(#2)가 있다
expect_out "s04: write_exec_boundary 의 BLOCK 검사(#2)가 FAIL" $'FAIL\t#2\t{"type":"verdict","level":"BLOCK","detector":"write_exec_boundary"}'
# 지운 폴더에 BLOCK 에 붙은 action 이 남지 않았다
expect_no_action "s04: write_exec_boundary 를 지운 폴더에 action 줄이 없음" "$TMP/strip_s04_write_exec_boundary"
# s08 대조: 원본은 통과
check "s08 대조: real_w5_s08 는 s08 기대를 통과" 0 "$FIX/real_w5_s08" "$S08"
# s08 에서 exec_identity 의 판정만 지운다
strip_detector "$FIX/real_w5_s08" exec_identity "$TMP/strip_s08_exec_identity"
# 지운 로그는 실패
check "s08: exec_identity 판정만 지우면 실패" 1 "$TMP/strip_s08_exec_identity" "$S08"
# 실패한 항목에 exec_identity 의 검사(#2)가 있다
expect_out "s08: exec_identity 의 SUSPECT 검사(#2)가 FAIL" $'FAIL\t#2\t{"type":"verdict","level":"SUSPECT","detector":"exec_identity"}'
# s08 에서 write_exec_boundary 의 판정만 지운다
strip_detector "$FIX/real_w5_s08" write_exec_boundary "$TMP/strip_s08_write_exec_boundary"
# 지운 로그는 실패
check "s08: write_exec_boundary 판정만 지우면 실패" 1 "$TMP/strip_s08_write_exec_boundary" "$S08"
# 실패한 항목에 write_exec_boundary 의 검사(#3)가 있다 (exec_identity 를 지운 경우와 다른 줄)
expect_out "s08: write_exec_boundary 의 SUSPECT 검사(#3)가 FAIL" $'FAIL\t#3\t{"type":"verdict","level":"SUSPECT","detector":"write_exec_boundary"}'
# n03 대조: 원본은 통과
check "n03 대조: real_w5_n03 는 n03 기대를 통과" 0 "$FIX/real_w5_n03" "$N03"
# n03 에서 write_exec_boundary 의 판정(SUSPECT 둘)을 지운다
strip_detector "$FIX/real_w5_n03" write_exec_boundary "$TMP/strip_n03_write_exec_boundary"
# 지운 로그는 실패
check "n03: write_exec_boundary 판정을 지우면 실패" 1 "$TMP/strip_n03_write_exec_boundary" "$N03"
# 실패한 항목에 write_exec_boundary 의 검사(#5)가 있다
expect_out "n03: write_exec_boundary 의 SUSPECT 검사(#5)가 FAIL" $'FAIL\t#5\t{"type":"verdict","level":"SUSPECT","detector":"write_exec_boundary"}'
# n06 대조: 원본은 통과
check "n06 대조: real_w5_n06 는 n06 기대를 통과" 0 "$FIX/real_w5_n06" "$N06"
# n06 에서 write_exec_boundary 의 판정(BLOCK)과 그 action 을 지운다
strip_detector "$FIX/real_w5_n06" write_exec_boundary "$TMP/strip_n06_write_exec_boundary"
# 지운 로그는 실패
check "n06: write_exec_boundary 판정(BLOCK)과 그 action 을 지우면 실패" 1 "$TMP/strip_n06_write_exec_boundary" "$N06"
# 실패한 항목에 write_exec_boundary 의 BLOCK 검사(#3)가 있다
expect_out "n06: write_exec_boundary 의 BLOCK 검사(#3)가 FAIL" $'FAIL\t#3\t{"type":"verdict","level":"BLOCK","detector":"write_exec_boundary"}'
# 지운 폴더에 BLOCK 에 붙은 action 이 남지 않았다
expect_no_action "n06: write_exec_boundary 를 지운 폴더에 action 줄이 없음" "$TMP/strip_n06_write_exec_boundary"
# real_s99_dummy_block 의 action 줄은 손으로 고친 줄이다 (위 "통과해야 하는 경우" 묶음 앞의 주의 주석)
# s99 대조: 원본은 통과
check "s99 대조: real_s99_dummy_block 은 s99 기대를 통과" 0 "$FIX/real_s99_dummy_block" "$S99"
# s99 에서 dummy_block 의 판정(BLOCK)과 그 action 을 지운다
strip_detector "$FIX/real_s99_dummy_block" dummy_block "$TMP/strip_s99_dummy_block"
# 지운 로그는 실패
check "s99: dummy_block 판정(BLOCK)과 그 action 을 지우면 실패" 1 "$TMP/strip_s99_dummy_block" "$S99"
# 실패한 항목에 dummy_block 의 BLOCK 검사(#2)가 있다
expect_out "s99: dummy_block 의 BLOCK 검사(#2)가 FAIL" $'FAIL\t#2\t{"type":"verdict","level":"BLOCK","detector":"dummy_block","filename":"/tmp/trigger"}'
# 지운 폴더에 BLOCK 에 붙은 action 이 남지 않았다
expect_no_action "s99: dummy_block 을 지운 폴더에 action 줄이 없음" "$TMP/strip_s99_dummy_block"
# s99 에서 dummy_suspect 의 판정만 지운다 (action 은 dummy_block 의 것이라 남는다)
strip_detector "$FIX/real_s99_dummy_block" dummy_suspect "$TMP/strip_s99_dummy_suspect"
# 지운 로그는 실패
check "s99: dummy_suspect 판정을 지우면 실패" 1 "$TMP/strip_s99_dummy_suspect" "$S99"
# 실패한 항목에 dummy_suspect 의 검사(#5)가 있다
expect_out "s99: dummy_suspect 의 SUSPECT 검사(#5)가 FAIL" $'FAIL\t#5\t{"type":"verdict","level":"SUSPECT","detector":"dummy_suspect","filename":"/tmp/trigger"}'

echo
# 마지막: 실패한 케이스가 없으면 종료 코드 0, 있으면 1.
if [[ $failures -eq 0 ]]; then
    echo "ALL PASSED (실패 0)"
    exit 0
fi
echo "FAILED (실패 $failures)"
exit 1
