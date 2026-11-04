#!/bin/bash
#
# tools/report.sh <세션 폴더> [옵션]
#
# ===== 이 파일의 역할 =====
# 세션 폴더 하나(events.jsonl, verdicts.jsonl, meta.json)를 읽어 사람이 읽는 "의심" 리포트를 표준 출력에 낸다.
# 통과/실패를 판정하지 않는다. 탐지기가 낸 판정과 그에 붙은 종료 대응을 정리해 보여 줄 뿐이다.
# 형식은 일반 텍스트이고 표 없이 항목별 목록(들여쓰기 한두 단계)이다. 경로가 길어도 한 줄로 낸다.
#
# ===== 옵션 =====
#   --loader-log <파일>  로더의 표준 오류 기록. "log stats: ... lost=N" 과 "ring buffer drops: ..." 줄을 읽는다.
#                        이 값은 로더 실행 전체의 합계라서 이 세션만의 값이 아니다. 없으면 "알 수 없음" 으로 쓴다
#   --scenario <이름>    리포트 머리에 적을 시나리오 이름. 없으면 "알 수 없음"
#   --include-dummy      시험용 dummy_ 탐지기의 판정도 보여 준다 (기본은 빼고 뺀 건수만 적는다)
#
# ===== 종료 코드 =====
#   0 : 리포트를 만들었다 (의심 판정이 있어도 0 이다. 이 도구는 판정을 하지 않는다)
#   2 : 입력·사용 오류 (세션 폴더 없음, 옵션 오류, 읽을 수 없는 파일, 깨진 JSON, 모르는 schema_version)
#   1 은 쓰지 않는다
#
# ===== 읽는 규칙 =====
# - 세 파일은 jq 로 한 번에 읽는다 (jq -s). 한 줄이라도 깨지면 그 파일 전체를 읽지 못한 것으로 보고 2 로 끝낸다
#   (tools/judge.sh 와 같은 방식. 줄 단위로 건너뛰면 빠진 판정이 "의심 없음" 처럼 보일 수 있어서).
# - schema_version 1 은 지금 형식, 0 은 4주차까지의 옛 형식이다. 0 은 경고를 붙여 읽고, 그 밖의 값은 2 로 끝낸다.
# - action 줄은 바로 앞 줄이 reason 이 같은 BLOCK verdict 일 때만 그 판정에 붙인다 (docs/log-schema-draft.md 의
#   "verdict 와의 연결"). 맞지 않으면 "연결 불명" 으로 따로 보여 준다.
# - EXEC 와 EXEC_PATH 는 1:1 이 아니어서 짝짓지 않고 개수만 보여 준다.

# 값이 정해지지 않은 변수를 쓰면 멈춘다 (변수 이름 오타를 일찍 잡는다)
set -u

# 사용법을 표준 오류에 내고 사용 오류(2)로 끝낸다
usage() {
    # 사용법 본문 (머리 주석의 줄 번호에 기대지 않고 여기서 직접 낸다)
    cat >&2 <<'EOF'
사용법: tools/report.sh <세션 폴더> [--loader-log <파일>] [--scenario <이름>] [--include-dummy]
EOF
    # 사용 오류
    exit 2
}

# 입력 오류 메시지를 [report] 접두어로 표준 오류에 내고 2 로 끝낸다
die() {
    # 메시지 한 줄
    echo "[report] $1" >&2
    # 입력 오류
    exit 2
}

# ---------- 인자 읽기 ----------
# 세션 폴더 (위치 인자)
SDIR=""
# 로더 로그 경로 (비어 있으면 받지 않은 것)
LOADER_LOG=""
# --loader-log 를 받았는가 (빈 경로를 준 경우와 구분한다)
HAVE_LOADER_LOG=0
# 시나리오 이름
SCENARIO=""
# dummy 판정을 포함할지 (0 이면 뺀다)
INCLUDE_DUMMY=0
# 인자가 남아 있는 동안 하나씩 본다 (leak_check.sh 의 while/case 방식)
while [[ $# -gt 0 ]]; do
    # 지금 인자의 종류로 나눈다
    case "$1" in
        # 로더 로그: 값이 하나 더 있어야 한다
        --loader-log) [[ $# -ge 2 ]] || usage; LOADER_LOG="$2"; HAVE_LOADER_LOG=1; shift 2 ;;
        # 시나리오 이름: 값이 하나 더 있어야 한다
        --scenario) [[ $# -ge 2 ]] || usage; SCENARIO="$2"; shift 2 ;;
        # dummy 포함: 값이 없는 스위치
        --include-dummy) INCLUDE_DUMMY=1; shift ;;
        # 도움말도 사용법으로 끝낸다
        -h|--help) usage ;;
        # 모르는 옵션은 사용 오류
        -*) usage ;;
        # 그 밖에는 위치 인자 (세션 폴더). 둘째 위치 인자는 사용 오류
        *) [[ -z "$SDIR" ]] || usage; SDIR="$1"; shift ;;
    esac
done
# 세션 폴더는 반드시 있어야 한다
[[ -n "$SDIR" ]] || usage

# jq 가 없으면 아무것도 읽을 수 없다
if ! command -v jq >/dev/null 2>&1; then
    # judge.sh 와 같은 안내
    die "jq 가 필요하다 (sudo apt install jq)"
fi
# 세션 폴더가 폴더로 있어야 한다
[[ -d "$SDIR" ]] || die "세션 폴더가 없음: $SDIR"

# 세션 폴더 안의 세 파일 경로
EV="$SDIR/events.jsonl"
# 판정과 대응 기록
VD="$SDIR/verdicts.jsonl"
# 세션 정보
META="$SDIR/meta.json"

# ---------- 파일 확인과 해석 ----------
# 파일이 있으면 1, 없으면 0 (없는 것은 리포트에 문구로 적는다)
HAVE_EV=0
# verdicts.jsonl 이 있는가
HAVE_VD=0
# meta.json 이 있는가
HAVE_META=0
# 있는 파일만 표시한다 (-e 는 무엇이든 있으면 참. 폴더나 링크 깨짐도 아래 -f/-r 에서 걸린다)
[[ -e "$EV" ]] && HAVE_EV=1
# verdicts.jsonl 도 같은 방식
[[ -e "$VD" ]] && HAVE_VD=1
# meta.json 도 같은 방식
[[ -e "$META" ]] && HAVE_META=1

# JSON Lines 파일 하나를 검사한다: 일반 파일이고, 읽을 수 있고, jq -s 로 읽히며, 모든 레코드가 객체여야 한다
check_jsonl() {
    # 검사할 파일
    local f="$1"
    # 일반 파일이고 읽을 수 있어야 한다
    [[ -f "$f" && -r "$f" ]] || die "읽을 수 없음: $f"
    # 한 번에 읽어 모든 레코드가 객체인지 본다 (깨진 줄이 있으면 jq 가 실패한다. 0바이트 파일은 빈 배열이라 통과)
    jq -se 'all(.[]; type == "object")' "$f" >/dev/null 2>&1 || die "해석하지 못함: $f"
}
# events.jsonl 이 있으면 검사
((HAVE_EV)) && check_jsonl "$EV"
# verdicts.jsonl 이 있으면 검사
((HAVE_VD)) && check_jsonl "$VD"
# meta.json 은 객체 하나여야 한다 (0바이트나 배열은 해석하지 못한 것으로 본다)
if ((HAVE_META)); then
    # 일반 파일이고 읽을 수 있어야 한다
    [[ -f "$META" && -r "$META" ]] || die "읽을 수 없음: $META"
    # 객체 하나인지 본다 (jq -e 는 결과가 true 일 때만 성공)
    jq -e 'type == "object"' "$META" >/dev/null 2>&1 || die "해석하지 못함: $META"
fi

# ---------- schema_version 확인 ----------
# 레코드를 읽을 파일 목록 (있는 jsonl 만)
RECFILES=()
# events.jsonl 이 있으면 넣는다
((HAVE_EV)) && RECFILES+=("$EV")
# verdicts.jsonl 이 있으면 넣는다
((HAVE_VD)) && RECFILES+=("$VD")
# 옛 형식(0) 레코드가 있는가
OLD_FORMAT=0
# 읽을 레코드 파일이 있을 때만 본다
if ((${#RECFILES[@]} > 0)); then
    # 모든 레코드의 schema_version 을 겹치지 않게 모은다 (없으면 null 로 나온다. 한 줄에 하나)
    versions="$(jq -rs '[.[] | .schema_version] | unique | .[] | tojson' "${RECFILES[@]}")"
    # 한 줄씩 본다 (값에 공백이 있어도 한 값으로 읽는다)
    while IFS= read -r v; do
        # 빈 줄(레코드가 하나도 없을 때)은 건너뛴다
        [[ -z "$v" ]] && continue
        # 지금 형식은 그대로
        if [[ "$v" == "1" ]]; then continue; fi
        # 옛 형식은 경고만 붙인다
        if [[ "$v" == "0" ]]; then OLD_FORMAT=1; continue; fi
        # 그 밖의 값(2, null 등)은 읽지 않는다
        die "모르는 schema_version: $v"
    done <<<"$versions"
fi

# ---------- 머리 ----------
# 세션 ID 와 그 출처를 정한다: meta.json 의 session_id, 없으면 레코드의 session 이 한 가지일 때 그 값, 없으면 폴더 이름
FOLDER_NAME="$(basename "$SDIR")"
# 기본은 폴더 이름
SESSION_ID="$FOLDER_NAME"
# 출처 표시
SESSION_SRC="폴더 이름"
# meta.json 의 값 (없으면 빈 문자열)
META_SID=""
# meta.json 이 있으면 session_id 를 읽는다
((HAVE_META)) && META_SID="$(jq -r '.session_id // empty | tostring' "$META")"
# 레코드의 session 값들 (겹치지 않게, 한 줄에 하나)
REC_SIDS=""
# 레코드 파일이 있으면 읽는다
((${#RECFILES[@]} > 0)) && REC_SIDS="$(jq -rs '[.[] | .session // empty | tostring] | unique | .[]' "${RECFILES[@]}")"
# 레코드의 session 값 개수
REC_SID_N="$(printf '%s' "$REC_SIDS" | grep -c . || true)"
# meta.json 값이 있으면 그것을 쓴다
if [[ -n "$META_SID" ]]; then
    # meta.json 이 정한 세션 ID
    SESSION_ID="$META_SID"; SESSION_SRC="meta.json"
# 레코드의 session 이 한 가지이면 그것을 쓴다
elif [[ "$REC_SID_N" == "1" ]]; then
    # 로더가 레코드에 쓴 세션 ID
    SESSION_ID="$REC_SIDS"; SESSION_SRC="레코드의 session"
fi

# 리포트 제목
echo "세션 리포트"
# 세션 ID 와 출처
echo "- 세션 ID: $SESSION_ID (출처: $SESSION_SRC)"
# 폴더 이름이 세션 ID 와 다르면 함께 적는다
[[ "$FOLDER_NAME" != "$SESSION_ID" ]] && echo "- 폴더 이름: $FOLDER_NAME"
# 레코드의 session 값이 둘 이상이거나 세션 ID 와 다르면 경고한다 (다른 세션의 기록이 섞였을 수 있다)
if [[ "$REC_SID_N" -gt 1 ]] || { [[ "$REC_SID_N" == "1" ]] && [[ "$REC_SIDS" != "$SESSION_ID" ]]; }; then
    # 레코드의 session 값들을 쉼표로 이어 보인다
    echo "- 경고: 레코드의 session 값이 세션 ID 와 다름: $(printf '%s' "$REC_SIDS" | paste -sd, -)"
fi
# 시나리오 이름 (옵션)
echo "- 시나리오: ${SCENARIO:-알 수 없음}"
# 리포트를 만든 시각
echo "- 만든 시각: $(date -Is)"
# 스냅샷 안내
echo "- 안내: 이 리포트는 만든 시점의 스냅샷이고, 탐지기가 낸 판정만 보여 준다."
# 옛 형식 경고
((OLD_FORMAT)) && echo "- 경고: 옛 형식(schema_version 0): 일부 필드가 없을 수 있다"

# ---------- 세션 정보 (meta.json) ----------
# 빈 줄로 구역을 나눈다
echo
# 구역 제목
echo "세션 정보 (meta.json)"
# meta.json 이 없으면 종료 정보도 없다
if ((HAVE_META == 0)); then
    # 없다는 사실과 그 결과
    echo "- 종료 정보 없음 (meta.json 이 없음)"
else
    # 각 값을 한 줄씩 낸다. 없는 키는 (없음). command 는 원문 앞 80자를 자른 뒤 개행을 \n 글자로 바꾼다
    jq -r '
      # 값이 없으면 (없음), 있으면 문자열로
      def s: if . == null then "(없음)" else tostring end;
      # 시작 시각 그대로
      "- 시작 시각: \(.started_at | s)",
      # 종료 시각 그대로
      "- 종료 시각: \(.ended_at | s)",
      # exit_code 가 없으면 종료 정보 없음
      (if has("exit_code") and .exit_code != null then "- exit_code: \(.exit_code)" else "- 종료 정보 없음 (exit_code 키가 없음)" end),
      # rootfs 그대로
      "- rootfs: \(.rootfs | s)",
      # command: 없으면 (없음), 있으면 원문 앞 80자를 자른 뒤 개행을 \n 글자로 바꾼다 (한 줄로 보이게)
      (if .command == null then "- command: (없음)"
       else (.command | tostring) as $c
            | if ($c | length) > 80 then "- command: \($c[0:80] | gsub("\n"; "\\n")) (길어서 줄임)"
              else "- command: \($c | gsub("\n"; "\\n"))" end
       end)
    ' "$META"
fi
# exit_code 해석 주의 (meta.json 유무와 상관없이 낸다)
echo "- 주의: exit_code 의 값만으로는 종료 원인을 가릴 수 없다. 137 이 로더의 종료 때문인지는 아래 판정 항목의 kill/sent 로만 가린다."

# ---------- 로더 정보 ----------
# 빈 줄로 구역을 나눈다
echo
# 구역 제목
echo "로더 정보"
# 로더 로그를 받지 않았으면 알 수 없다
if ((HAVE_LOADER_LOG == 0)); then
    # 받지 않았다는 사실
    echo "- 로더 로그를 주지 않아 lost 와 드롭은 알 수 없음"
# 받았지만 읽을 수 없으면 알 수 없다 (리포트는 계속 만든다)
elif [[ ! -f "$LOADER_LOG" || ! -r "$LOADER_LOG" ]]; then
    # 읽지 못했다는 사실과 경로
    echo "- 로더 로그를 읽지 못해 lost 와 드롭은 알 수 없음: $LOADER_LOG"
else
    # 값을 찾지 못하면 알 수 없음으로 둔다
    LOST="알 수 없음"; D_EXEC="알 수 없음"; D_TAG="알 수 없음"; D_PATH="알 수 없음"
    # log stats 줄들 (로더를 여러 번 띄운 기록이면 여러 줄일 수 있다)
    stats_lines="$(grep -E 'log stats: .*lost=[0-9]+' "$LOADER_LOG")"
    # 드롭 줄들
    drop_lines="$(grep -E 'ring buffer drops: exec=[0-9]+ tag_hit=[0-9]+ exec_path=[0-9]+' "$LOADER_LOG")"
    # 마지막 log stats 줄에서 lost 값을 꺼낸다
    if [[ "$(printf '%s\n' "$stats_lines" | tail -n 1)" =~ lost=([0-9]+) ]]; then LOST="${BASH_REMATCH[1]}"; fi
    # 마지막 드롭 줄에서 세 값을 꺼낸다
    if [[ "$(printf '%s\n' "$drop_lines" | tail -n 1)" =~ exec=([0-9]+)\ tag_hit=([0-9]+)\ exec_path=([0-9]+) ]]; then
        # 세 칸
        D_EXEC="${BASH_REMATCH[1]}"; D_TAG="${BASH_REMATCH[2]}"; D_PATH="${BASH_REMATCH[3]}"
    fi
    # 합계 한 줄
    echo "- 이 로더 실행 전체의 합계(이 세션만의 값이 아님): lost=$LOST, 드롭 exec=$D_EXEC tag_hit=$D_TAG exec_path=$D_PATH"
    # log stats 줄이 둘 이상이면 마지막 값을 썼다고 알린다
    n_stats="$(printf '%s' "$stats_lines" | grep -c . || true)"
    # 여러 번 띄운 기록일 때만
    [[ "$n_stats" -gt 1 ]] && echo "- 참고: 로더 로그에 log stats 줄이 ${n_stats}개 있어 마지막 값을 썼다"
fi

# ---------- 관측 (events.jsonl) ----------
# 빈 줄로 구역을 나눈다
echo
# 구역 제목
echo "관측 (events.jsonl)"
# 이벤트 줄 수 (events.jsonl 이 없으면 -1)
N_EV=-1
# events.jsonl 이 있으면 종류별로 센다
if ((HAVE_EV)); then
    # type 이 event 인 줄 수
    N_EV="$(jq -s '[.[] | select(.type == "event")] | length' "$EV")"
    # 종류별 개수. 셋 말고 다른 종류가 있으면 따로 이어 붙인다
    jq -rs '
      # event 레코드만
      [.[] | select(.type == "event") | (.event.kind // "kind 없음" | tostring)] as $k
      # 세 종류의 개수
      | "- 이벤트 \($k | length)줄: EXEC \([$k[] | select(. == "EXEC")] | length), EXEC_PATH \([$k[] | select(. == "EXEC_PATH")] | length), TAG_HIT \([$k[] | select(. == "TAG_HIT")] | length)"
      # 그 밖의 종류
        + ([$k[] | select(. != "EXEC" and . != "EXEC_PATH" and . != "TAG_HIT")] | group_by(.) | map(", \(.[0]) \(length)") | add // "")
    ' "$EV"
    # 짝짓지 않는다는 안내
    echo "- 참고: EXEC 와 EXEC_PATH 는 1:1 이 아니므로 짝짓지 않는다"
else
    # 파일이 없다는 사실
    echo "- events.jsonl 이 없음 (관측 기록을 읽을 수 없음)"
fi

# ---------- 판정 (verdicts.jsonl) ----------
# 빈 줄로 구역을 나눈다
echo
# 구역 제목
echo "판정 (verdicts.jsonl)"
# verdicts.jsonl 이 없으면 0건과 다른 문구로 끝낸다 (0바이트 파일과 구분)
if ((HAVE_VD == 0)); then
    # 없다는 사실
    echo "- verdicts.jsonl 이 없음 (판정 기록을 읽을 수 없음)"
    # 리포트는 만들었다
    exit 0
fi
# 판정, 종료 대응 연결, 연결 불명을 한 번에 만든다
jq -rs --argjson inc "$INCLUDE_DUMMY" --argjson nev "$N_EV" '
  # 값이 없으면 (없음), 있으면 문자열로
  def s: if . == null then "(없음)" else tostring end;
  # 수준을 사람이 읽을 문구로
  def lvl: if . == "BLOCK" then "BLOCK (사후 종료 요청, 실행을 막지 못함)"
           elif . == "SUSPECT" then "SUSPECT (기록만)"
           else s end;
  # 시험용 dummy_ 탐지기의 판정인가
  def isdummy: ((.detector // "") | tostring | startswith("dummy_"));
  # result 값을 사람이 읽을 설명으로 (모르는 값이나 없는 값은 빈 문자열)
  def explain: if . == "already_gone" then " — 종료 대상이 이미 없었다 (세션이 BLOCK 전에 끝남)"
               elif . == "sent" then " — 세션 종료를 요청했다"
               elif . == "failed" then " — 종료 요청에 실패했다"
               elif . == "skipped" then " — 세션을 찾지 못해 종료하지 않았다"
               elif . == "not_sent" then " — 관찰 모드라 종료하지 않았다"
               else "" end;
  # 종료 대응 한 줄: action/result (detail, errno n) 뒤에 설명. result 가 없는 옛 형식은 결과 기록 없음 (설명 없음)
  def act: "\(.action | s)/" + (if .result == null then "결과 기록 없음"
                                else "\(.result) (\(.detail | s), errno \(.errno | s))" + (.result | explain) end);
  # 줄 전체
  . as $all
  # 레코드 개수
  | ($all | length) as $n
  # action 줄의 위치들
  | [range(0; $n) | select($all[.].type == "action")] as $acts
  # 바로 앞 줄이 reason 이 같은 BLOCK verdict 인 action 위치들
  | [$acts[] | select(. > 0 and $all[. - 1].type == "verdict" and $all[. - 1].level == "BLOCK"
                      and $all[. - 1].reason == $all[.].reason)] as $linked
  # 그 밖의 action 위치들 (연결 불명)
  | [$acts[] | . as $i | select(any($linked[]; . == $i) | not)] as $orphan
  # verdict 줄의 위치들
  | [range(0; $n) | select($all[.].type == "verdict")] as $vidx
  # 세션의 첫 BLOCK verdict 위치 (dummy 포함. 로더는 탐지기를 가리지 않고 첫 BLOCK 에 대응한다)
  | ([$vidx[] | select($all[.].level == "BLOCK")] | first) as $first
  # dummy 판정 위치들
  | [$vidx[] | select($all[.] | isdummy)] as $didx
  # 보여 줄 판정 위치들
  | (if $inc == 1 then $vidx else [$vidx[] | select(($all[.] | isdummy) | not)] end) as $shown
  # dummy 판정을 뺐는지 넣었는지
  | (if $inc == 1 then "- dummy 판정도 포함함 (--include-dummy, \($didx | length)건)"
     else "- dummy 판정 \($didx | length)건 제외 (--include-dummy 로 포함)" end),
  # 보여 줄 판정이 없을 때
    (if ($shown | length) == 0 then
       # 0건 문구
       (if $inc == 1 then "- 판정 0건" else "- 실제 탐지기 판정 0건" end),
       # 관측이 있었는지로 0건의 뜻을 가린다
       (if $nev < 0 then "- events.jsonl 이 없어 관측 여부를 알 수 없음"
        elif $nev > 0 then "- 관측은 있었다 (이벤트 \($nev)줄)"
        else "- 관측된 이벤트가 없음 (정상으로 볼 수 없음)" end)
     else
       # 건수 (dummy 를 뺐으면 실제 탐지기 판정, 넣었으면 그냥 판정)
       (if $inc == 1 then "- 판정 \($shown | length)건" else "- 실제 탐지기 판정 \($shown | length)건" end),
       # 판정 하나씩
       ($shown | to_entries[] | .key as $k | .value as $j | $all[$j] as $v
        # 항목 제목은 대괄호 번호 (건수 줄과 모양이 다르게)
        | "- [\($k + 1)]",
          # 수준
          "  - 수준: \($v.level | lvl)",
          # 탐지기 이름
          "  - 탐지기: \($v.detector | s)",
          # reason 그대로
          "  - 이유: \($v.reason | s)",
          # 이벤트 종류
          "  - 이벤트 종류: \($v.event.kind | s)",
          # 실행 요청 이름
          "  - 실행 요청 이름: \($v.event.filename | s)",
          # pid
          "  - pid: \($v.event.pid | s)",
          # TAG_HIT 의 두 cgroup. 두 값이 다 있으면 같은지 다른지를 실행한 쪽 줄 끝에 덧붙인다
          (if $v.event.kind == "TAG_HIT" then
             "  - 파일을 쓴 세션의 cgroup: \($v.event.cgroup_id | s)",
             "  - 실행한 쪽의 cgroup: \($v.event.exec_cgroup_id | s)"
               + (if $v.event.cgroup_id == null or $v.event.exec_cgroup_id == null then ""
                  elif $v.event.cgroup_id == $v.event.exec_cgroup_id then " (같음: 같은 세션 안 실행)"
                  else " (다름: 세션 밖 실행)" end)
           else empty end),
          # EXEC_PATH 의 실제 실행 파일 이름과 위치
          (if $v.event.kind == "EXEC_PATH" then
             "  - 실제 실행 파일 이름: \($v.event.final_name | s)",
             "  - 위치 (부모 / 조부모): \($v.event.parent_name | s) / \($v.event.grandparent_name | s)"
           else empty end),
          # BLOCK 이면 종료 대응을 붙인다
          (if $v.level == "BLOCK" then
             (if any($linked[]; . == $j + 1) then "  - 종료 대응: \($all[$j + 1] | act)"
              elif $j == $first then "  - 종료 대응 기록 없음 (세션의 첫 BLOCK 인데 바로 다음 줄에 대응 기록이 없음)"
              else "  - 종료 대응 없음 (세션의 첫 BLOCK 에만 붙는다)" end)
           else empty end))
     end),
  # 뺀 dummy 판정에 붙은 종료 대응은 숨기지 않는다 (세션이 종료됐을 수 있으므로)
    (if $inc == 1 then empty
     else ($linked[] | select($all[. - 1] | isdummy)
           | "- 제외한 dummy 판정에 연결된 종료 대응: \($all[.] | act) (이유: \($all[.].reason | s))") end),
  # 연결 불명 종료 대응 (몇 번째 줄인지 함께)
    ($orphan[] | "- 연결 불명 종료 대응 (verdicts.jsonl \(. + 1)번째 줄): \($all[.] | act) (이유: \($all[.].reason | s))")
' "$VD"
# 이 jq 가 실패하면(출력을 이미 일부 냈더라도) 리포트가 불완전하므로 입력 오류로 끝낸다
if [[ $? -ne 0 ]]; then
    # 불완전하다는 사실을 표준 오류에 알린다
    die "판정 구역을 만들지 못함"
fi
# 리포트를 만들었다
exit 0
