#!/bin/bash
#
# tools/test_report.sh
#
# ===== 이 파일의 역할 =====
# 리포트 생성기(report.sh)가 "보여야 할 문구를 보이고, 보이면 안 되는 문구를 보이지 않으며, 입력 오류는 2 로 끝나는가"를
# 검증하는 단위 테스트. 커널, 컨테이너, root 권한이 필요 없다.
# 입력은 fixtures/ 의 옛 로그(schema_version 0)와, 이 시험이 임시 폴더에 직접 쓰는 지금 형식(schema_version 1)의 세션이다.
#
# ===== 구조 =====
# test_judge.sh 와 test_runner.sh 를 따른다.
#   check "<설명>" <기대 종료 코드> <report.sh 인자...>  : 리포트를 실행해 출력을 OUT 에 모으고 종료 코드를 비교한다
#   expect_text "<설명>" "<문구>"                         : 바로 앞 check 의 출력에 문구가 있어야 한다
#   expect_no_text "<설명>" "<문구>"                      : 바로 앞 check 의 출력에 문구가 없어야 한다
#   expect_text_after "<설명>" "<첫째>" "<둘째>" [줄 수]  : 첫째 문구가 처음 나온 줄부터 N줄(기본 12) 안에 둘째 문구가 있어야 한다
#   expect_no_text_in_item "<설명>" "<첫째>" "<문구>"     : 첫째 문구가 처음 나온 줄부터 다음 판정 항목("- [")이 시작하기 전까지 문구가 없어야 한다
#
# 사용법: tools/test_report.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u
# 이 스크립트가 있는 폴더(tools)의 절대 경로
HERE="$(cd "$(dirname "$0")" && pwd)"
# 검사 대상
REPORT="$HERE/report.sh"
# 옛 fixture 폴더
FIX="$HERE/fixtures"

# 실패한 검사 수
failures=0
# 시험 중에 만드는 임시 세션들을 담을 폴더
TMP="$(mktemp -d)"
# 리포트 출력(표준 출력과 표준 오류)을 모으는 파일
OUT="$(mktemp)"
# 어떻게 끝나든 이 시험이 만든 임시 파일과 폴더를 지운다 (test_judge.sh 와 같은 방식)
trap 'rm -f "$OUT"; rm -rf "$TMP"' EXIT

# 리포트를 실행하고 종료 코드가 기대와 같은지 확인한다
check() {
    # 설명, 기대 종료 코드, 실제 종료 코드
    local msg="$1" want="$2" got
    # 앞의 두 인자를 버리고 나머지를 report.sh 인자로 쓴다
    shift 2
    # 표준 출력과 표준 오류를 함께 OUT 에 모은다
    "$REPORT" "$@" >"$OUT" 2>&1
    # 바로 종료 코드를 저장한다
    got=$?
    # 기대와 같으면 통과
    if [[ "$got" == "$want" ]]; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 이유
        printf '  FAIL  %s (기대 종료 코드 %s, 실제 %s)\n' "$msg" "$want" "$got"
        # 리포트 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUT"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 바로 앞 check 의 출력에 문구가 있는지 확인한다 (-F 글자 그대로, -- 뒤는 찾을 문자열)
expect_text() {
    # 설명과 문구
    local msg="$1" text="$2"
    # 있으면 통과
    if grep -qF -- "$text" "$OUT"; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 찾던 문구
        printf '  FAIL  %s (출력에 "%s" 가 없음)\n' "$msg" "$text"
        # 리포트 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUT"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 바로 앞 check 의 출력에 문구가 없는지 확인한다 (expect_text 의 반대. 같은 형식)
expect_no_text() {
    # 설명과 문구
    local msg="$1" text="$2"
    # 없으면 통과
    if ! grep -qF -- "$text" "$OUT"; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 나오면 안 되는 문구
        printf '  FAIL  %s (출력에 "%s" 가 있음)\n' "$msg" "$text"
        # 리포트 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUT"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 바로 앞 check 의 출력에서 첫째 문구가 처음 나온 줄부터 N줄 안에 둘째 문구가 있는지 확인한다 (위치 검사)
expect_text_after() {
    # 설명, 첫째 문구, 둘째 문구, 줄 수(없으면 12), 첫째 문구의 줄 번호
    local msg="$1" first="$2" second="$3" n="${4:-12}" at
    # 첫째 문구가 처음 나온 줄 번호 (grep -n 은 "번호:내용" 을 낸다. 첫 줄만, 번호만)
    at="$(grep -nF -- "$first" "$OUT" | head -n 1 | cut -d: -f1)"
    # 첫째 문구가 있고, 그 줄부터 N줄 안에 둘째 문구가 있으면 통과
    if [[ -n "$at" ]] && sed -n "${at},$((at + n - 1))p" "$OUT" | grep -qF -- "$second"; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 두 문구, 줄 수
        printf '  FAIL  %s ("%s" 부터 %s줄 안에 "%s" 가 없음)\n' "$msg" "$first" "$n" "$second"
        # 리포트 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUT"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 바로 앞 check 의 출력에서 첫째 문구가 처음 나온 줄부터 다음 판정 항목 제목 전까지 문구가 없는지 확인한다 (항목 안 음성 검사)
expect_no_text_in_item() {
    # 설명, 첫째 문구, 없어야 할 문구, 첫째 문구의 줄 번호
    local msg="$1" first="$2" text="$3" at
    # 첫째 문구가 처음 나온 줄 번호
    at="$(grep -nF -- "$first" "$OUT" | head -n 1 | cut -d: -f1)"
    # 첫째 문구가 있고, 그 줄부터 다음 "- [" 줄 전까지(awk 로 자름)에 문구가 없으면 통과
    if [[ -n "$at" ]] && ! awk -v s="$at" 'NR == s { p = 1 } NR > s && /^- \[/ { exit } p' "$OUT" | grep -qF -- "$text"; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 두 문구 (첫째 문구가 없어도 실패로 본다)
        printf '  FAIL  %s ("%s" 항목 안에 "%s" 가 있거나 항목을 찾지 못함)\n' "$msg" "$first" "$text"
        # 리포트 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUT"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# ---------- 임시 세션 만들기 (지금 로더 출력 형식, schema_version 1) ----------
# 임시 세션들의 세션 ID
SID="20261105-000000-100"
# 임시 세션 폴더를 만들고 meta.json 을 쓴다. 인자: 폴더 이름. limits 등 시험에 필요 없는 키는 뺐다
make_session() {
    # 폴더 경로
    local d="$TMP/$1"
    # 폴더를 만든다
    mkdir -p "$d"
    # 시험에 필요한 키만 있는 meta.json (키 10개 중 limits, cgroup_path, command 는 일부러 뺐다)
    cat >"$d/meta.json" <<EOF
{
  "session_id": "$SID",
  "cgroup_id": 7,
  "started_at": "2026-11-05T00:00:00+09:00",
  "schema_version": 1,
  "rootfs": "/rootfs",
  "ended_at": "2026-11-05T00:00:01+09:00",
  "exit_code": 0
}
EOF
}

# EXEC 이벤트 한 줄 (지금 로더 형식)
EV_EXEC='{"schema_version":1,"type":"event","session":"20261105-000000-100","logged_at_ms":1000,"event":{"kind":"EXEC","pid":200,"cgroup_id":7,"ts_ns":10,"filename":"/bin/ls"}}'
# EXEC_PATH 이벤트 한 줄
EV_PATH='{"schema_version":1,"type":"event","session":"20261105-000000-100","logged_at_ms":1000,"event":{"kind":"EXEC_PATH","pid":200,"cgroup_id":7,"ts_ns":11,"filename":"/bin/ls","final_name":"busybox","parent_name":"bin","grandparent_name":"/"}}'
# TAG_HIT 이벤트 한 줄 (쓴 세션 7, 실행한 쪽 9)
EV_TAG='{"schema_version":1,"type":"event","session":"20261105-000000-100","logged_at_ms":1001,"event":{"kind":"TAG_HIT","pid":201,"cgroup_id":7,"ts_ns":20,"exec_cgroup_id":9,"tag_ts_ns":3,"tag_write_count":1,"dev":40,"ino":5,"filename":"/tmp/payload"}}'
# 세션 밖 실행 BLOCK 판정 한 줄 (reason 에 한글)
V_BLOCK='{"schema_version":1,"type":"verdict","session":"20261105-000000-100","logged_at_ms":1001,"level":"BLOCK","detector":"write_exec_boundary","reason":"세션 밖 실행, 쓴 지 0.017초: /tmp/payload","event":{"kind":"TAG_HIT","pid":201,"cgroup_id":7,"ts_ns":20,"exec_cgroup_id":9,"tag_ts_ns":3,"tag_write_count":1,"dev":40,"ino":5,"filename":"/tmp/payload"}}'
# 둘째 BLOCK 판정 (reason 이 다름)
V_BLOCK2='{"schema_version":1,"type":"verdict","session":"20261105-000000-100","logged_at_ms":1002,"level":"BLOCK","detector":"write_exec_boundary","reason":"세션 밖 실행, 쓴 지 0.500초: /tmp/payload2","event":{"kind":"TAG_HIT","pid":202,"cgroup_id":7,"ts_ns":30,"exec_cgroup_id":9,"tag_ts_ns":4,"tag_write_count":1,"dev":40,"ino":6,"filename":"/tmp/payload2"}}'
# 첫 BLOCK 과 같은 reason 의 종료 대응 (kill/sent)
A_SENT='{"schema_version":1,"type":"action","session":"20261105-000000-100","logged_at_ms":1001,"cgroup_id":7,"action":"kill","result":"sent","detail":"written","errno":0,"reason":"세션 밖 실행, 쓴 지 0.017초: /tmp/payload"}'
# reason 이 다른 종료 대응 (연결 불명이어야 한다)
A_OTHER='{"schema_version":1,"type":"action","session":"20261105-000000-100","logged_at_ms":1001,"cgroup_id":7,"action":"kill","result":"sent","detail":"written","errno":0,"reason":"다른 이유"}'
# 관찰 모드의 대응 (would_kill/not_sent)
A_OBSERVE='{"schema_version":1,"type":"action","session":"20261105-000000-100","logged_at_ms":1001,"cgroup_id":7,"action":"would_kill","result":"not_sent","detail":"observe_mode","errno":0,"reason":"세션 밖 실행, 쓴 지 0.017초: /tmp/payload"}'
# result 가 없는 옛 형식의 대응 (w1d4~w3d1 의 스텁 모양)
A_STUB='{"schema_version":0,"type":"action","session":"20261105-000000-100","logged_at_ms":1001,"cgroup_id":7,"action":"would_kill","reason":"세션 밖 실행, 쓴 지 0.017초: /tmp/payload"}'
# exec_identity 의 EXEC_PATH 판정 한 줄
V_PATH='{"schema_version":1,"type":"verdict","session":"20261105-000000-100","logged_at_ms":1003,"level":"SUSPECT","detector":"exec_identity","reason":"[L] 요청 이름과 다른 실제 파일(임시 위치): 요청 ls, 실제 payload (위치 /tmp)","event":{"kind":"EXEC_PATH","pid":203,"cgroup_id":7,"ts_ns":40,"filename":"/tmp/bin/ls","final_name":"payload","parent_name":"tmp","grandparent_name":"/"}}'

# 같은 세션 안 실행 SUSPECT 판정 (쓴 세션과 실행한 쪽이 둘 다 7)
V_SAME='{"schema_version":1,"type":"verdict","session":"20261105-000000-100","logged_at_ms":1004,"level":"SUSPECT","detector":"write_exec_boundary","reason":"같은 세션 안 실행, 쓴 지 0.001초: /tmp/a.out","event":{"kind":"TAG_HIT","pid":204,"cgroup_id":7,"ts_ns":50,"exec_cgroup_id":7,"tag_ts_ns":49,"tag_write_count":1,"dev":40,"ino":8,"filename":"/tmp/a.out"}}'
# 첫 BLOCK 과 같은 reason 의 already_gone 대응 (세션이 먼저 끝난 경우)
A_GONE='{"schema_version":1,"type":"action","session":"20261105-000000-100","logged_at_ms":1001,"cgroup_id":7,"action":"kill","result":"already_gone","detail":"enoent","errno":2,"reason":"세션 밖 실행, 쓴 지 0.017초: /tmp/payload"}'

# (a) 이벤트는 있고 verdicts.jsonl 이 0바이트
make_session zero_a
# 이벤트 두 줄
printf '%s\n%s\n' "$EV_EXEC" "$EV_PATH" >"$TMP/zero_a/events.jsonl"
# 0바이트 판정 파일
: >"$TMP/zero_a/verdicts.jsonl"
# (b) 두 파일 모두 0바이트
make_session zero_b
# 0바이트 이벤트 파일
: >"$TMP/zero_b/events.jsonl"
# 0바이트 판정 파일
: >"$TMP/zero_b/verdicts.jsonl"
# (c) verdicts.jsonl 이 없음
make_session zero_c
# 이벤트 한 줄만
printf '%s\n' "$EV_EXEC" >"$TMP/zero_c/events.jsonl"

# BLOCK 바로 다음에 같은 reason 의 kill/sent, 그리고 exec_identity 판정
make_session linked
# 이벤트 세 줄 (EXEC, EXEC_PATH, TAG_HIT 각 하나)
printf '%s\n%s\n%s\n' "$EV_EXEC" "$EV_PATH" "$EV_TAG" >"$TMP/linked/events.jsonl"
# BLOCK, 대응, EXEC_PATH 판정
printf '%s\n%s\n%s\n' "$V_BLOCK" "$A_SENT" "$V_PATH" >"$TMP/linked/verdicts.jsonl"
# BLOCK 둘 중 첫째에만 대응이 있음
make_session twoblock
# 이벤트 한 줄
printf '%s\n' "$EV_TAG" >"$TMP/twoblock/events.jsonl"
# 첫 BLOCK, 대응, 둘째 BLOCK
printf '%s\n%s\n%s\n' "$V_BLOCK" "$A_SENT" "$V_BLOCK2" >"$TMP/twoblock/verdicts.jsonl"
# 대응이 있는데 바로 앞 BLOCK 과 reason 이 다름
make_session orphan
# 이벤트 한 줄
printf '%s\n' "$EV_TAG" >"$TMP/orphan/events.jsonl"
# BLOCK 과 reason 이 다른 대응
printf '%s\n%s\n' "$V_BLOCK" "$A_OTHER" >"$TMP/orphan/verdicts.jsonl"
# 관찰 모드
make_session observe
# 이벤트 한 줄
printf '%s\n' "$EV_TAG" >"$TMP/observe/events.jsonl"
# BLOCK 과 would_kill/not_sent
printf '%s\n%s\n' "$V_BLOCK" "$A_OBSERVE" >"$TMP/observe/verdicts.jsonl"
# result 가 없는 옛 형식의 대응
make_session stub
# 이벤트 한 줄
printf '%s\n' "$EV_TAG" >"$TMP/stub/events.jsonl"
# BLOCK 과 스텁 대응
printf '%s\n%s\n' "$V_BLOCK" "$A_STUB" >"$TMP/stub/verdicts.jsonl"
# 모르는 schema_version (events.jsonl 한 줄의 값만 2)
make_session v2
# 버전만 2 로 바꾼 이벤트
printf '%s\n' "${EV_EXEC/\"schema_version\":1/\"schema_version\":2}" >"$TMP/v2/events.jsonl"
# 0바이트 판정 파일
: >"$TMP/v2/verdicts.jsonl"
# (d) events.jsonl 이 없고 verdicts.jsonl 은 0바이트
make_session zero_d
# 0바이트 판정 파일 (events.jsonl 은 만들지 않는다)
: >"$TMP/zero_d/verdicts.jsonl"
# EXEC_PATH 판정 하나뿐인 세션 (두 cgroup 표시가 붙으면 안 된다)
make_session pathonly
# 이벤트 한 줄
printf '%s\n' "$EV_PATH" >"$TMP/pathonly/events.jsonl"
# exec_identity 판정 한 줄
printf '%s\n' "$V_PATH" >"$TMP/pathonly/verdicts.jsonl"
# 같은 세션 안 실행 (두 cgroup 이 같은 TAG_HIT 판정)
make_session same
# 이벤트 한 줄
printf '%s\n' "$EV_TAG" >"$TMP/same/events.jsonl"
# 같은 세션 SUSPECT 판정
printf '%s\n' "$V_SAME" >"$TMP/same/verdicts.jsonl"
# BLOCK 다음에 already_gone 대응
make_session gone
# 이벤트 한 줄
printf '%s\n' "$EV_TAG" >"$TMP/gone/events.jsonl"
# BLOCK 과 already_gone
printf '%s\n%s\n' "$V_BLOCK" "$A_GONE" >"$TMP/gone/verdicts.jsonl"
# lost 와 드롭이 모두 0 인 로더 로그 (0 이 알 수 없음으로 오인되지 않는지)
cat >"$TMP/loader0.err" <<'EOF'
[loader] log stats: writes=5 slow(>5ms)=0 max=3us lost=0
[loader] ring buffer drops: exec=0 tag_hit=0 exec_path=0
EOF
# 로더 로그 (log stats 줄과 드롭 줄)
cat >"$TMP/loader.err" <<'EOF'
[loader] ready (sessions root: /tmp/x/sessions, mode: kill, detectors: exec_identity,write_exec_boundary)
[loader] log stats: writes=10 slow(>5ms)=0 max=15us lost=3
[loader] ring buffer drops: exec=1 tag_hit=0 exec_path=2
EOF

# ---------- 시험 ----------
echo "[사용 오류는 2]"
# 인자 없음
check "인자가 없으면 사용 오류" 2
# 없는 세션 폴더
check "세션 폴더가 없으면 입력 오류" 2 "$TMP/없는폴더"
# 모르는 옵션
check "알 수 없는 옵션은 사용 오류" 2 "$TMP/linked" --bogus
# --loader-log 뒤에 값이 없음
check "--loader-log 의 값이 없으면 사용 오류" 2 "$TMP/linked" --loader-log
# 위치 인자가 둘
check "세션 폴더를 둘 주면 사용 오류" 2 "$TMP/linked" "$TMP/zero_a"

echo "[깨진 JSON 은 2]"
# bad_corrupt 는 verdicts.jsonl 의 한 줄이 끝에서 잘려 있다
check "verdicts.jsonl 이 깨진 fixture 는 입력 오류" 2 "$FIX/bad_corrupt"
# 오류 문구
expect_text "해석하지 못함 문구" "[report] 해석하지 못함:"
# 어느 파일인지
expect_text "깨진 파일 이름을 알려 줌" "bad_corrupt/verdicts.jsonl"

echo "[옛 형식(schema_version 0)은 경고와 함께 읽음]"
# real_s99_dummy_block: 4일차 실제 로그. 단 action 줄은 04f5b2f 에서 사람이 result/detail/errno 를 넣어 고친 줄이다
check "옛 형식 fixture 도 리포트를 만든다" 0 "$FIX/real_s99_dummy_block"
# 옛 형식 경고
expect_text "옛 형식 경고" "옛 형식(schema_version 0): 일부 필드가 없을 수 있다"
# meta.json 이 없는 fixture
expect_text "meta.json 이 없으면 종료 정보 없음" "종료 정보 없음 (meta.json 이 없음)"
# dummy 판정 네 건(dummy_suspect 3, dummy_block 1)을 뺀다
expect_text "dummy 판정을 빼고 건수를 적음" "dummy 판정 4건 제외"
# 뺀 판정은 보이지 않는다
expect_no_text "뺀 dummy 판정은 판정 항목으로 보이지 않음" "탐지기: dummy_"
# dummy 를 빼면 남는 판정이 없다 (dummy 를 빼지 않으면 이 문구가 나오지 않는다)
expect_text "dummy 를 빼면 실제 탐지기 판정 0건" "실제 탐지기 판정 0건"
# 뺀 dummy BLOCK 에 붙은 종료 대응은 숨기지 않는다
expect_text "뺀 dummy 판정의 종료 대응은 보임" "제외한 dummy 판정에 연결된 종료 대응: kill/sent"
# 그 줄에도 설명이 붙는다
expect_text "뺀 dummy 판정의 종료 대응에도 설명" "제외한 dummy 판정에 연결된 종료 대응: kill/sent (written, errno 0) — 세션 종료를 요청했다"
# --include-dummy 를 주면 dummy 판정이 보인다
check "--include-dummy 도 리포트를 만든다" 0 "$FIX/real_s99_dummy_block" --include-dummy
# dummy_block 판정이 판정 항목으로 보인다
expect_text "--include-dummy 면 dummy_block 판정이 보임" "탐지기: dummy_block"
# 제외 문구는 나오지 않는다
expect_no_text "--include-dummy 면 제외 문구가 없음" "건 제외"
# dummy_block 의 BLOCK 아래에 대응이 붙는다
expect_text "--include-dummy 면 대응이 BLOCK 아래에 붙음" "  - 종료 대응: kill/sent (written, errno 0)"

echo "[모르는 schema_version 은 2]"
# events.jsonl 한 줄의 schema_version 이 2
check "schema_version 2 는 입력 오류" 2 "$TMP/v2"
# 오류 문구
expect_text "모르는 버전 값을 알려 줌" "[report] 모르는 schema_version: 2"

echo "[판정 0건의 세 경우를 서로 다른 문구로]"
# (a) 이벤트 있음, 판정 0바이트
check "(a) 판정 0바이트도 리포트를 만든다" 0 "$TMP/zero_a"
# 관측은 있었다
expect_text "(a) 관측은 있었다" "관측은 있었다 (이벤트 2줄)"
# 다른 두 문구는 없다
expect_no_text "(a) 이벤트 없음 문구가 없음" "관측된 이벤트가 없음"
# 다른 두 문구는 없다
expect_no_text "(a) 판정 파일 없음 문구가 없음" "verdicts.jsonl 이 없음"
# limits, command 가 없는 meta.json 도 오류가 아니다
expect_text "(a) 없는 키는 (없음) 으로 보임" "- command: (없음)"
# (b) 두 파일 모두 0바이트
check "(b) 두 파일 0바이트도 리포트를 만든다" 0 "$TMP/zero_b"
# 관측이 없다
expect_text "(b) 관측된 이벤트가 없음" "관측된 이벤트가 없음 (정상으로 볼 수 없음)"
# 다른 두 문구는 없다
expect_no_text "(b) 관측은 있었다 문구가 없음" "관측은 있었다"
# 다른 두 문구는 없다
expect_no_text "(b) 판정 파일 없음 문구가 없음" "verdicts.jsonl 이 없음"
# (c) verdicts.jsonl 이 없음
check "(c) 판정 파일이 없어도 리포트를 만든다" 0 "$TMP/zero_c"
# 판정 파일이 없다
expect_text "(c) verdicts.jsonl 이 없음" "verdicts.jsonl 이 없음 (판정 기록을 읽을 수 없음)"
# 다른 두 문구는 없다
expect_no_text "(c) 관측은 있었다 문구가 없음" "관측은 있었다"
# 다른 두 문구는 없다
expect_no_text "(c) 이벤트 없음 문구가 없음" "관측된 이벤트가 없음"
# (d) events.jsonl 이 없음
check "(d) events.jsonl 이 없어도 리포트를 만든다" 0 "$TMP/zero_d"
# 관측 구역에서 읽을 수 없다고 말한다
expect_text "(d) events.jsonl 이 없음" "events.jsonl 이 없음 (관측 기록을 읽을 수 없음)"
# 판정 0건의 뜻도 알 수 없다고 말한다
expect_text "(d) 관측 여부를 알 수 없음" "events.jsonl 이 없어 관측 여부를 알 수 없음"

echo "[판정 항목과 종료 대응 연결]"
# BLOCK 바로 다음 줄에 같은 reason 의 kill/sent
check "연결된 대응이 있는 세션" 0 "$TMP/linked"
# 대응이 BLOCK 항목 아래(들여쓴 줄)에 붙는다
expect_text "BLOCK 아래에 종료 대응" "  - 종료 대응: kill/sent (written, errno 0)"
# 대응이 첫 판정 항목 [1] 안에 있다 (위치 검사)
expect_text_after "종료 대응이 [1] 항목 안에 있음" "- [1]" "  - 종료 대응: kill/sent"
# sent 의 설명
expect_text "sent 대응의 설명" "종료 대응: kill/sent (written, errno 0) — 세션 종료를 요청했다"
# 건수 줄
expect_text "건수 줄은 실제 탐지기 판정 N건" "- 실제 탐지기 판정 2건"
# 쓴 세션과 실행한 쪽이 다르다는 표시
expect_text "두 cgroup 이 다르면 다름 표시" "실행한 쪽의 cgroup: 9 (다름: 세션 밖 실행)"
# 연결 불명은 없다
expect_no_text "연결된 대응은 연결 불명이 아님" "연결 불명"
# BLOCK 수준 문구
expect_text "BLOCK 수준 문구" "수준: BLOCK (사후 종료 요청, 실행을 막지 못함)"
# SUSPECT 수준 문구
expect_text "SUSPECT 수준 문구" "수준: SUSPECT (기록만)"
# 한글 reason 이 그대로
expect_text "한글 reason 이 깨지지 않고 그대로" "이유: 세션 밖 실행, 쓴 지 0.017초: /tmp/payload"
# TAG_HIT 의 쓴 세션
expect_text "TAG_HIT 의 쓴 세션 cgroup" "파일을 쓴 세션의 cgroup: 7"
# TAG_HIT 의 실행한 쪽
expect_text "TAG_HIT 의 실행한 쪽 cgroup" "실행한 쪽의 cgroup: 9"
# EXEC_PATH 의 실제 이름
expect_text "EXEC_PATH 의 실제 실행 파일 이름" "실제 실행 파일 이름: payload"
# EXEC_PATH 의 위치
expect_text "EXEC_PATH 의 위치" "위치 (부모 / 조부모): tmp / /"
# 이벤트 종류별 개수
expect_text "이벤트 종류별 개수" "EXEC 1, EXEC_PATH 1, TAG_HIT 1"
# 로더 로그를 주지 않음
expect_text "로더 로그가 없으면 알 수 없음" "로더 로그를 주지 않아 lost 와 드롭은 알 수 없음"
# 둘째 BLOCK 에는 대응이 없다
check "BLOCK 이 둘인 세션" 0 "$TMP/twoblock"
# 둘째 BLOCK 의 문구
expect_text "둘째 BLOCK 은 대응 없음 문구" "종료 대응 없음 (세션의 첫 BLOCK 에만 붙는다)"
# 첫 BLOCK 에는 대응이 붙는다
expect_text "첫 BLOCK 에는 대응이 붙음" "종료 대응: kill/sent"
# 첫 BLOCK 의 대응은 [1] 항목 안에 있다 (위치 검사)
expect_text_after "첫 BLOCK [1] 안에 종료 대응" "- [1]" "종료 대응: kill/sent"
# 둘째 BLOCK [2] 안에는 대응 없음 문구가 있다 (위치 검사)
expect_text_after "둘째 BLOCK [2] 안에 대응 없음 문구" "- [2]" "종료 대응 없음 (세션의 첫 BLOCK 에만 붙는다)"
# reason 이 다른 대응
check "reason 이 다른 대응이 있는 세션" 0 "$TMP/orphan"
# 연결 불명으로 따로
expect_text "reason 이 다르면 연결 불명" "연결 불명 종료 대응 (verdicts.jsonl 2번째 줄): kill/sent"
# BLOCK 아래에는 붙지 않는다
expect_no_text "reason 이 다른 대응은 BLOCK 아래에 붙지 않음" "  - 종료 대응: kill/sent"
# 첫 BLOCK 인데 대응이 없다
expect_text "첫 BLOCK 의 대응 기록 없음 문구" "종료 대응 기록 없음 (세션의 첫 BLOCK 인데 바로 다음 줄에 대응 기록이 없음)"
# 연결 불명 줄에도 설명이 붙는다
expect_text "연결 불명 대응에도 설명" "연결 불명 종료 대응 (verdicts.jsonl 2번째 줄): kill/sent (written, errno 0) — 세션 종료를 요청했다"
# 관찰 모드
check "관찰 모드 대응이 있는 세션" 0 "$TMP/observe"
# would_kill/not_sent 그대로
expect_text "관찰 모드 대응이 그대로 보임" "종료 대응: would_kill/not_sent (observe_mode, errno 0)"
# not_sent 의 설명
expect_text "not_sent 대응의 설명" "— 관찰 모드라 종료하지 않았다"
# result 가 없는 옛 대응
check "result 가 없는 옛 대응이 있는 세션" 0 "$TMP/stub"
# 결과 기록 없음
expect_text "result 가 없으면 결과 기록 없음" "종료 대응: would_kill/결과 기록 없음"
# 설명은 붙지 않는다
expect_no_text "result 가 없으면 설명이 붙지 않음" "— "
# already_gone 대응
check "already_gone 대응이 있는 세션" 0 "$TMP/gone"
# already_gone 의 설명
expect_text "already_gone 대응의 설명" "종료 대응: kill/already_gone (enoent, errno 2) — 종료 대상이 이미 없었다 (세션이 BLOCK 전에 끝남)"
# 같은 세션 안 실행
check "같은 세션 안 실행 판정이 있는 세션" 0 "$TMP/same"
# 쓴 세션과 실행한 쪽이 같다는 표시
expect_text "두 cgroup 이 같으면 같음 표시" "실행한 쪽의 cgroup: 7 (같음: 같은 세션 안 실행)"
# EXEC_PATH 판정뿐인 세션
check "EXEC_PATH 판정뿐인 세션" 0 "$TMP/pathonly"
# EXEC_PATH 판정에는 같음 표시가 없다
expect_no_text "EXEC_PATH 판정에는 같음 표시가 없음" "(같음"
# EXEC_PATH 판정에는 다름 표시가 없다
expect_no_text "EXEC_PATH 판정에는 다름 표시가 없음" "(다름"
# 건수 줄과 항목 제목
expect_text_after "건수 줄 다음에 [1] 항목" "- 실제 탐지기 판정 1건" "- [1]" 2

echo "[로더 로그]"
# log stats 와 드롭 줄이 있는 로더 로그
check "로더 로그를 준 리포트" 0 "$TMP/linked" --loader-log "$TMP/loader.err"
# 합계 문구와 값
expect_text "로더 실행 전체의 합계와 값" "이 로더 실행 전체의 합계(이 세션만의 값이 아님): lost=3, 드롭 exec=1 tag_hit=0 exec_path=2"
# 알 수 없음 문구는 없다
expect_no_text "로더 로그를 주면 알 수 없음 문구가 없음" "lost 와 드롭은 알 수 없음"
# lost 와 드롭이 모두 0 인 로더 로그
check "lost=0 로더 로그를 준 리포트" 0 "$TMP/linked" --loader-log "$TMP/loader0.err"
# 0 이 그대로 나온다
expect_text "lost 와 드롭이 0 이면 0 그대로" "lost=0, 드롭 exec=0 tag_hit=0 exec_path=0"
# 0 을 알 수 없음으로 바꾸지 않는다
expect_no_text "lost=0 을 알 수 없음으로 쓰지 않음" "lost 와 드롭은 알 수 없음"
# 없는 로더 로그
check "없는 로더 로그를 줘도 리포트를 만든다" 0 "$TMP/linked" --loader-log "$TMP/없는로그"
# 읽지 못했다는 문구
expect_text "읽지 못한 로더 로그는 알 수 없음" "로더 로그를 읽지 못해 lost 와 드롭은 알 수 없음"
# 시나리오 이름
check "시나리오 이름을 준 리포트" 0 "$TMP/linked" --scenario s04_write_exec_live
# 머리에 시나리오 이름
expect_text "시나리오 이름이 머리에 보임" "- 시나리오: s04_write_exec_live"

# ---------- 실제 로더 출력 fixture (schema_version 1, w5d1 VM) ----------
# real_w5_n03, n06, s04, s08 은 w5d1 VM 의 한 번의 러너 실행(로더 실행 하나)이 남긴 세션 폴더를 그대로 복사한 것이다.
# real_w5_loader.err 는 그 로더 실행의 표준 오류다. real_w5_s00 은 다른 로더 실행의 세션이라 이 로더 로그에 해당하지 않는다.
# 파일 내용은 한 글자도 바꾸지 않았다 (개인·환경 문자열도 그대로).
echo "[실제 출력 fixture: n03 (같은 세션 SUSPECT 둘)]"
# n03 리포트
check "n03 리포트를 만든다" 0 "$FIX/real_w5_n03"
# 건수 줄
expect_text "n03 실제 탐지기 판정 2건" "- 실제 탐지기 판정 2건"
# 첫 항목
expect_text "n03 항목 [1]" "- [1]"
# 둘째 항목
expect_text "n03 항목 [2]" "- [2]"
# 같은 세션 표시
expect_text "n03 같은 세션 표시" "(같음: 같은 세션 안 실행)"
# dummy 제외 건수
expect_text "n03 dummy 판정 18건 제외" "dummy 판정 18건 제외"
# 이벤트 종류별 개수
expect_text "n03 이벤트 개수" "EXEC 18, EXEC_PATH 16, TAG_HIT 2"
# exit_code
expect_text "n03 exit_code 0" "- exit_code: 0"
# 시나리오 이름을 주지 않았다
expect_text "n03 시나리오 알 수 없음" "- 시나리오: 알 수 없음"
# BLOCK 이 없으니 판정 항목 아래 종료 대응 줄도 없다 (세션 정보의 주의 문구에도 "종료 대응" 이 들어 있어 항목 줄 모양으로 찾는다)
expect_no_text "n03 종료 대응 없음" "  - 종료 대응"

echo "[실제 출력 fixture: n06 (알려진 오탐 BLOCK + already_gone)]"
# n06 리포트
check "n06 리포트를 만든다" 0 "$FIX/real_w5_n06"
# BLOCK 수준 문구
expect_text "n06 BLOCK 수준" "수준: BLOCK (사후 종료 요청, 실행을 막지 못함)"
# 세션 밖 실행 표시
expect_text "n06 다름 표시" "(다름: 세션 밖 실행)"
# 종료 대응
expect_text "n06 종료 대응 already_gone" "종료 대응: kill/already_gone (enoent, errno 2)"
# 종료 대응 설명
expect_text "n06 already_gone 설명" "종료 대상이 이미 없었다"
# dummy 제외 건수
expect_text "n06 dummy 판정 8건 제외" "dummy 판정 8건 제외"
# 종료 대응이 [1] 항목 안에 있다
expect_text_after "n06 종료 대응이 [1] 안에 있음" "- [1]" "종료 대응: kill/already_gone"
# 같은 로더 실행의 로그를 준다
check "n06 리포트에 로더 로그를 준다" 0 "$FIX/real_w5_n06" --loader-log "$FIX/real_w5_loader.err"
# 로더 실행 전체의 값
expect_text "n06 로더 로그 값" "lost=0, 드롭 exec=0 tag_hit=0 exec_path=0"
# 이 세션만의 값이 아니라는 안내
expect_text "n06 로더 값은 세션만의 값이 아님" "이 세션만의 값이 아님"

echo "[실제 출력 fixture: s04 (BLOCK + kill/sent, exit_code 137)]"
# s04 리포트
check "s04 리포트를 만든다" 0 "$FIX/real_w5_s04"
# 종료 대응
expect_text "s04 종료 대응 sent" "종료 대응: kill/sent (written, errno 0)"
# 종료 대응 설명
expect_text "s04 sent 설명" "세션 종료를 요청했다"
# exit_code 137
expect_text "s04 exit_code 137" "- exit_code: 137"
# exit_code 해석 주의
expect_text "s04 exit_code 주의 문구" "exit_code 의 값만으로는 종료 원인을 가릴 수 없다"

echo "[실제 출력 fixture: s08 (exec_identity [L] + 같은 세션 SUSPECT)]"
# s08 리포트
check "s08 리포트를 만든다" 0 "$FIX/real_w5_s08"
# 건수 줄
expect_text "s08 실제 탐지기 판정 2건" "- 실제 탐지기 판정 2건"
# exec_identity 판정
expect_text "s08 exec_identity 판정" "탐지기: exec_identity"
# write_exec_boundary 판정
expect_text "s08 write_exec_boundary 판정" "탐지기: write_exec_boundary"
# [L] 이유 그대로
expect_text "s08 [L] 이유 그대로" "이유: [L] 요청 이름과 다른 실제 파일(임시 위치): 요청 ls, 실제 payload (위치 /tmp)"
# 실제 실행 파일 이름
expect_text "s08 실제 실행 파일 이름" "실제 실행 파일 이름: payload"
# 위치
expect_text "s08 위치" "위치 (부모 / 조부모): tmp / /"
# 실제 실행 파일 이름이 exec_identity 항목 안에 있다
expect_text_after "s08 실제 이름이 exec_identity 항목 안에 있음" "탐지기: exec_identity" "실제 실행 파일 이름: payload" 6
# exec_identity 항목 안에는 같음 표시가 없다 (TAG_HIT 판정의 같음 표시는 다른 항목에 있다)
expect_no_text_in_item "s08 exec_identity 항목에 같음 표시 없음" "탐지기: exec_identity" "(같음"
# exec_identity 항목 안에는 다름 표시가 없다
expect_no_text_in_item "s08 exec_identity 항목에 다름 표시 없음" "탐지기: exec_identity" "(다름"

echo "[실제 출력 fixture: s00 (실제 판정 0건, 다른 로더 실행)]"
# s00 리포트
check "s00 리포트를 만든다" 0 "$FIX/real_w5_s00"
# 0건
expect_text "s00 실제 탐지기 판정 0건" "실제 탐지기 판정 0건"
# 관측은 있었다
expect_text "s00 관측은 있었다" "관측은 있었다 (이벤트 6줄)"
# 폴더 이름이 meta.json 의 세션 ID 와 다르다
expect_text "s00 폴더 이름 표시" "폴더 이름: real_w5_s00"
# dummy 제외 건수
expect_text "s00 dummy 판정 3건 제외" "dummy 판정 3건 제외"
# 판정 항목이 없다
expect_no_text "s00 판정 항목 없음" "- [1]"

# 결과 요약
echo
# 실패가 없으면 0
if ((failures == 0)); then
    # 통과
    echo "ALL PASSED (실패 0)"
    # 종료 코드 0
    exit 0
fi
# 실패 수와 함께
echo "FAILED (실패 $failures)"
# 종료 코드 1
exit 1
