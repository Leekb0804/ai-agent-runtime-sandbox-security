#!/bin/bash
#
# tools/judge.sh <세션 폴더 | 로그 파일> <expect.json>
#
# ===== 이 파일의 역할 =====
# 세션 로그를 시나리오의 기대값(expect.json)과 비교해서 통과/실패를 판정한다.
# 러너(run_scenarios.sh)가 시나리오마다 호출하고, 커널이나 컨테이너 없이도 돌아서 단위 테스트가 가능하다
# (tools/test_judge.sh).
#
# ===== 입력 =====
#   세션 폴더 : events.jsonl 과 verdicts.jsonl 을 "둘 다" 읽어서 한 목록으로 합친다. (러너가 이렇게 쓴다)
#   로그 파일 : 그 파일 하나만 읽는다. (단위 테스트용)
# 레코드의 "type" 으로 구분되므로 두 파일을 합쳐도 섞이지 않는다 (event / verdict / action).
#
# ===== 왜 이벤트 로그도 읽나 =====
# 판정(verdicts.jsonl)만 보면 "무해한 시나리오가 실행됐다"는 사실을 탐지기에 의존해서 확인하게 된다.
# 예를 들어 "ls 가 실행됐고 의심으로 기록됐다"를 양성 검사로 쓰면, 더미 탐지기를 빼는 순간 시나리오가 깨진다.
# 이벤트 로그(커널이 본 사실)를 양성 검사에 쓰면 탐지기가 바뀌어도 시나리오는 그대로다.
#
# ===== 종료 코드 =====
#   0 : 모든 검사 통과
#   1 : 하나 이상 실패 (어느 검사가 왜 실패했는지 출력)
#   2 : 입력 오류 (파일이 없거나 형식이 틀림). 테스트가 "통과"로 오인되지 않도록 실패(1)와 구분한다
#
# ===== expect.json 형식 =====
# {
#   "description": "사람이 읽을 설명",
#   "expect": [
#     { "note": "이 검사의 의도",
#       "match": { "type": "verdict", "level": "BLOCK", "detector": "dummy_block", "filename": "/tmp/trigger" },
#       "count": 1 }
#   ]
# }
#
#   match : 로그의 레코드 중 이 필드들이 "전부" 같은 것만 센다. 쓸 수 있는 필드는 아래 flat 정의 참고.
#   개수 조건 (셋 중 하나):
#     "count": N           정확히 N 개 (N 이 0 이면 "그런 레코드가 없어야 한다"는 음성 검사)
#     "min": A, "max": B   A 개 이상, B 개 이하 (둘 중 하나만 써도 됨)
#     아무것도 안 쓰면      최소 1 개
#
# ===== 왜 YAML 이 아니라 JSON 인가 =====
# bash 에는 YAML 파서가 없고 jq 는 JSON 만 읽는다. yq 같은 도구를 추가 의존성으로 들이지 않으려고 JSON 을 쓴다.
#
# ===== 양성 검사가 반드시 하나 있어야 한다 =====
# "BLOCK 이 없어야 한다" 같은 음성 검사만 있으면, 로더가 아무것도 못 봐서 로그가 텅 비어 있어도 통과해 버린다
# (가짜 통과). 그래서 "무엇인가 있어야 한다"는 양성 검사가 최소 하나 없는 expect.json 은 입력 오류(2)로 거부한다.

# ===== 이 파일을 읽는 방법 (쉘 문법이 낯설다면) =====
# 이 파일에는 두 가지 언어가 섞여 있다.
#   - bash : 인자 확인, 파일 목록 만들기, 종료 코드 정하기. 대부분의 줄이 이쪽이다.
#   - jq   : JSON 을 읽고 조건을 계산하는 별도의 작은 언어. 작은따옴표 '...' 안에 들어 있는 부분이다.
# jq 부분 (아래 RESULT=$( 로 시작하는 큰 덩어리)은 처음에는 "로그 줄을 세어 기대와 비교하는 상자"로 보고 넘어가도 된다.
# 이 파일이 맞게 동작한다는 증거는 코드를 눈으로 읽는 것보다 tools/test_judge.sh 의 16개 테스트이다.
# 전체 흐름: 인자 확인 -> expect.json 형식 검증 -> 읽을 로그 파일 목록 만들기 -> jq 로 검사별 개수 비교 -> 종료 코드 정하기
# set -u : 값이 정해지지 않은 변수를 쓰면 오류로 즉시 멈춘다. 변수 이름을 잘못 쓰는 실수를 일찍 잡으려는 설정이다.
#          그래서 아래처럼 인자를 받을 때는 "${1:-}" 처럼 기본값을 함께 쓴다.
set -u

# $1 : 스크립트 뒤에 쓴 첫 번째 인자 (tools/judge.sh <여기> expect.json). $2 는 두 번째 인자이다.
# ${1:-} : $1 이 없으면 빈 문자열을 쓴다. set -u 때문에 이렇게 하지 않으면 인자 없이 실행했을 때 오류로 멈춘다.
# 변수에 값을 넣을 때는 = 앞뒤에 공백을 쓰면 안 된다 (LOG = ... 는 오류).
LOG="${1:-}"
# $2 : 두 번째 인자 = 기대 파일 (expect.json)
EXP="${2:-}"

# [[ 조건 ]] : 조건 검사. 참이면 then 아래를 실행한다. if 문은 fi 로 닫는다.
# -z "문자열" : 문자열이 비어 있으면 참.   || : "또는".
# 즉 "로그 인자나 기대 파일 인자 둘 중 하나라도 비어 있으면" 사용법을 알려 주고 끝낸다.
if [[ -z "$LOG" || -z "$EXP" ]]; then
    # >&2 : 이 메시지를 표준 오류(에러용 출력 통로)로 보낸다. 정상 결과(표준 출력)와 섞이지 않게 하는 관례이다.
    # $0 : 이 스크립트 자신의 이름 (사용법에 실행 이름을 그대로 보여 주려고 쓴다).
    echo "사용법: $0 <세션 폴더 | 로그 파일> <expect.json>" >&2
    # exit 2 : 종료 코드 2 로 프로그램을 끝낸다. 코드의 뜻은 위 "종료 코드" 설명 참고 (0 통과, 1 검사 실패, 2 입력 오류).
    exit 2
fi
# command -v jq : jq 라는 명령이 설치되어 있으면 그 경로를 출력하고 성공, 없으면 실패한다.
# ! : 결과를 뒤집는다. 즉 "jq 가 없으면"이라는 뜻이다.
# >/dev/null 2>&1 : 이 확인 명령이 내는 글자를 화면에 보이지 않게 버린다 (/dev/null 은 무엇을 써도 사라지는 쓰레기통 파일).
#    2>&1 은 오류 출력(2번)도 표준 출력(1번)이 가는 곳으로 보내라는 뜻이라서, 둘 다 버려진다.
if ! command -v jq >/dev/null 2>&1; then
    echo "[judge] jq 가 필요하다 (sudo apt install jq)" >&2
    exit 2
fi
# -f 경로 : 그 경로에 일반 파일이 있으면 참 (폴더인지 확인하는 것은 -d).
# 앞의 ! 때문에 "기대 파일이 없으면" 이라는 뜻이 된다.
if [[ ! -f "$EXP" ]]; then
    echo "[judge] 기대 파일이 없음: $EXP" >&2
    exit 2
fi

# ---------- 기대 파일 검증 ----------
# 1) 올바른 JSON 이고 expect 가 비어 있지 않은 배열인가
# jq -e '식' 파일 : 파일(JSON)을 읽고 식을 계산한다.
#   -e 옵션 : 식의 마지막 결과가 true 면 성공(종료 코드 0), false 나 null 이면 실패(1)로 끝나게 한다.
#             즉 jq 의 계산 결과를 쉘의 if 가 읽을 수 있는 성공/실패로 바꿔 주는 스위치이다.
#             JSON 이 깨져 있으면 jq 가 오류(종료 코드 5)로 끝나므로 이것도 "실패"로 취급된다.
#   그래서 if ! jq -e ... 는 "식이 참이 아니면 (또는 파일이 깨졌으면)" 이라는 뜻이다.
# 식 읽는 법 (| 는 왼쪽 결과를 오른쪽으로 넘기는 파이프이다):
#   .expect | type == "array"  : expect 값을 꺼내서(.expect) 그 종류(type)가 "array" 인가?
#   .expect | length > 0       : expect 의 길이가 0 보다 큰가 (비어 있지 않은가)?
#   and                        : 둘 다 참이어야 참.
# expect 가 배열이라는 약속은 이 코드가 만드는 것이 아니라, 각 시나리오의 expect.json 이
# "expect": [ ... ] 처럼 [ ] 로 감싼 목록으로 쓰여 있다는 약속이다 (위 "expect.json 형식" 참고).
# 여기서는 그 약속이 지켜졌는지만 확인한다.
if ! jq -e '(.expect | type == "array") and (.expect | length > 0)' "$EXP" >/dev/null 2>&1; then
    echo "[judge] expect.json 형식 오류: .expect 는 비어 있지 않은 배열이어야 한다 ($EXP)" >&2
    exit 2
fi
# 2) 모든 검사에 match 객체가 있는가
# 식 읽는 법 (안쪽부터):
#   .expect[]                   : expect 목록의 항목(검사 하나)을 하나씩 꺼낸다.
#   .match | type == "object"   : 그 항목의 match 값을 꺼내서 종류(type)가 "object" 인가? ("object" 는 { } 로 쓴 묶음) -> true/false.
#                                 match 가 아예 없으면 값이 null 이고 종류는 "null" 이라서 false 가 된다.
#                                 "match 가 존재하거나 object 이거나" 라는 or 조건이 아니다.
#                                 "match 가 있고, 그것이 object 여야 한다" 는 하나의 검사이다 (없으면 object 가 아니므로 자연히 실패).
#   [ ... ]                     : 항목마다 나온 true/false 를 모아 목록으로 만든다 (예: [true, true]).
#   | all                       : 그 목록이 전부 true 이면 true.
if ! jq -e '[.expect[] | (.match | type == "object")] | all' "$EXP" >/dev/null 2>&1; then
    echo "[judge] expect.json 형식 오류: 모든 검사에 match 객체가 필요하다 ($EXP)" >&2
    exit 2
fi
# 3) 양성 검사가 하나 이상 있는가 (count > 0, 또는 count 없이 min 이 1 이상(기본 1))
# 식 읽는 법 (양성 검사 = "있어야 한다"는 검사가 하나라도 있는가):
#   select(조건)                          : 조건이 참인 항목만 남긴다.
#   .count != null and .count > 0         : count 가 적혀 있고 0 보다 크다 ("정확히 N 개, N >= 1").
#   .count == null and (.min // 1) >= 1   : count 가 없고 min 이 1 이상이다.
#                                           (.min // 1) 의 // 는 "앞의 값이 없거나 null 이면 뒤의 값"이라는 기본값 연산이다.
#                                           min 도 안 적혀 있으면 1 로 본다 (조건을 안 쓰면 "최소 1 개"가 기본이라 양성이다).
#   [ ... ] | length > 0                  : 그런 항목이 하나 이상 남았는가.
if ! jq -e '[.expect[] | select((.count != null and .count > 0) or (.count == null and (.min // 1) >= 1))] | length > 0' "$EXP" >/dev/null 2>&1; then
    echo "[judge] expect.json 에 양성 검사(\"있어야 한다\")가 하나도 없다. 빈 로그로도 통과하는 시나리오는 허용하지 않는다 ($EXP)" >&2
    exit 2
fi

# ---------- 로그 읽기 ----------
# 읽을 파일 목록을 정한다. 없는 파일은 빈 로그로 취급한다 (양성 검사가 있으므로 빈 로그는 어차피 실패한다).
# 쉘의 배열 문법.
#   FILES=()          빈 배열 만들기
#   FILES+=("값")     배열 끝에 원소 하나 추가
#   ${#FILES[@]}      원소 개수
#   "${FILES[@]}"     원소 전부 (각각 따옴표로 보호되어 공백이 있어도 안전하다)
FILES=()
# $LOG 가 폴더일 수도, 파일일 수도 있는 이유 (경우가 나뉜 이유):
#   - 폴더 : 러너(run_scenarios.sh)가 세션 폴더를 통째로 넘긴다. 안에 events.jsonl 과 verdicts.jsonl 이 있고 둘 다 읽는다.
#            실제 사용은 이쪽이다.
#   - 파일 : 로그 파일 하나만 있는 경우를 다룰 수 있도록 둔 호환 모드이다. tools/test_judge.sh 에 이 모드를 확인하는
#            테스트가 하나 있다. 러너는 쓰지 않으므로 필요 없다고 판단하면 이 분기와 그 테스트 한 개를 함께 지워도 된다.
# -d 경로 : 그 경로가 폴더이면 참.
if [[ -d "$LOG" ]]; then
    # for f in A B; do ... done : A 와 B 를 차례로 f 에 넣어 가며 안쪽을 반복한다.
    for f in "$LOG/events.jsonl" "$LOG/verdicts.jsonl"; do
        # A && B : A 가 성공하면 B 를 실행한다. 즉 그 파일이 실제로 있을 때만 FILES 에 추가한다 (없는 파일은 건너뜀).
        [[ -f "$f" ]] && FILES+=("$f")
    done
# elif : 앞의 if 조건이 거짓일 때 다음 조건을 검사한다. 여기서는 "폴더는 아니고, 일반 파일이면" 이다.
elif [[ -f "$LOG" ]]; then
    FILES+=("$LOG")
fi
# (( 수식 )) : 숫자 계산/비교. 쉘의 [[ ]] 와 달리 == 나 > 같은 기호를 숫자 비교에 그대로 쓸 수 있다.
# ${#FILES[@]} 는 FILES 의 원소 개수이므로, 이 줄은 "읽을 파일이 하나도 없으면" 이다.
if ((${#FILES[@]} == 0)); then
    # /dev/null : 읽으면 내용이 아무것도 없는 빈 파일처럼 동작한다. jq 에 줄 입력이 최소 하나는 있어야 하므로 빈 로그 대신 넣는다.
    FILES+=(/dev/null)
fi

# ---------- 비교 ----------
# jq -s 는 JSON Lines 전체를 하나의 배열로 읽는다 (slurp).
# --slurpfile exp 는 기대 파일을 $exp[0] 으로 읽는다.
#
# flat : 로그 레코드를 비교하기 쉽게 한 단계 평평하게 만든다.
#        event 레코드와 verdict 레코드는 filename, kind 가 .event 아래에 있고 action 레코드에는 .event 가 없다.
#        없는 필드는 null 이 되어 어떤 값과도 같지 않다.
# matches : 레코드가 match 의 모든 키-값을 만족하는가
#
# 출력 한 줄 = 검사 하나:  OK|FAIL <탭> #번호 <탭> match <탭> 기대 ..., 실제 N개 <탭> note
# ---------- 아래 jq 프로그램 읽는 법 (지금 당장 다 이해하지 않아도 된다) ----------
# 쉘 쪽 문법:
#   RESULT=$( 명령 )  : 명령이 출력하는 글자를 RESULT 변수에 담는다 ("명령 치환").
#   '...'             : 작은따옴표 안의 글자는 쉘이 손대지 않고 그대로 jq 에게 넘긴다.
#                       그래서 안에 $i, \( ) 같은 것이 있어도 쉘이 해석하지 않는다.
#   "${FILES[@]}"     : 끝에 붙은 인자로, jq 가 읽을 로그 파일들이다.
#   2>/dev/null       : jq 의 오류 메시지는 버린다 (깨진 JSON 은 아래에서 종료 코드로 따로 처리한다).
# jq 옵션:
#   -s                : 입력의 모든 줄(JSON 한 줄 = 레코드 하나)을 읽어서 하나의 배열로 만든다 (slurp = 한꺼번에 퍼 담기).
#   -r                : 출력 문자열을 따옴표 없이 있는 그대로 내보낸다 (raw).
#   --slurpfile exp 파일 : 기대 파일을 읽어서 변수 $exp 에 넣는다. 파일 내용이 길이 1 짜리 배열로 들어가므로
#                       $exp[0] 이 expect.json 전체이다.
# jq 문법 메모:
#   .필드, .a.b       : 객체에서 값 꺼내기 (.event.filename 은 event 안의 filename)
#   a | b             : 파이프. a 의 결과를 b 의 입력으로 넘긴다 (쉘의 | 와 비슷하다)
#   x // y            : x 가 없거나 null 이면 y (기본값)
#   { type, level }   : { "type": .type, "level": .level } 의 줄임 표기
#   select(조건)       : 조건이 참인 것만 남긴다
#   map(f)            : 배열의 모든 원소에 f 를 적용한 새 배열
#   식 as $이름        : 식의 결과에 이름을 붙여 둔다
#   "글자 \(식)"       : 문자열 안에 식의 결과를 끼워 넣는다
#   \t                : 탭 문자 (출력 한 줄의 칸을 탭으로 나눈다. run_scenarios.sh 의 print_judge 가 탭으로 다시 쪼갠다)
# 각 줄이 하는 일:
#   def flat: { ... }                     로그 레코드 -> 비교용으로 평평하게 만든 객체. filename, kind, pid 는 .event 안에 있어서
#                                         (.event.filename // null) 로 꺼내고, 없으면(action 레코드) null 로 둔다.
#   def matches($m): ...                  레코드(.)가 match($m)의 모든 (키, 값) 쌍과 같은 값을 가졌는가
#   (map(flat)) as $recs                  모든 로그 레코드를 flat 으로 바꿔 $recs 로 저장
#   | ($exp[0].expect) | to_entries[]     expect 배열을 (번호 .key, 항목 .value) 쌍으로 하나씩 꺼낸다.
#                                         여기부터 아래 줄들은 "검사 하나"마다 한 번씩 실행된다.
#   | .key as $i | .value as $c           번호는 $i, 검사 하나는 $c 로 저장
#   | ( ... | length) as $n               match 조건에 맞는 레코드만 골라서(select) 개수를 센다 -> $n
#   | (if $c.count != null then ... ) as $ok     기대 개수와 실제 개수 $n 이 맞는가 -> $ok (true/false)
#   | (if ... end) as $want               사람이 읽을 기대 문구 ("정확히 1개", "최소 1개, 최대 2개" 등)
#   | "\(...)\t#\(...)..."                한 줄로 조립해서 출력: OK 또는 FAIL, #번호, match 내용, 기대 vs 실제, note
# 예 (s99 의 BLOCK 검사): match = { type: verdict, level: BLOCK }, count = 1.
#    레코드 6 줄 중 두 조건이 모두 맞는 줄이 1 개 -> $n = 1, $ok = true
#    -> "OK  #2  {...}  기대 정확히 1개, 실제 1개  <note>" 가 한 줄 출력된다.
RESULT=$(jq -s -r --slurpfile exp "$EXP" '
  def flat: {
      type, level, detector, action, session, reason,
      filename: (.event.filename // null),
      kind:     (.event.kind // null),
      pid:      (.event.pid // null)
  };
  def matches($m): . as $r | $m | to_entries | all(.[]; $r[.key] == .value);

  (map(flat)) as $recs
  | ($exp[0].expect) | to_entries[]
  | .key as $i | .value as $c
  | ($recs | map(select(matches($c.match))) | length) as $n
  | (if $c.count != null
       then ($n == $c.count)
       else (($n >= ($c.min // 1)) and (($c.max == null) or ($n <= $c.max)))
     end) as $ok
  | (if $c.count != null
       then "정확히 \($c.count)개"
       else "최소 \($c.min // 1)개" + (if $c.max != null then ", 최대 \($c.max)개" else "" end)
     end) as $want
  | "\(if $ok then "OK  " else "FAIL" end)\t#\($i + 1)\t\($c.match | tojson)\t기대 \($want), 실제 \($n)개\t\($c.note // "")"
' "${FILES[@]}" 2>/dev/null)

# jq 자체가 실패하면(로그에 깨진 JSON 줄이 있는 경우 등) 입력 오류로 본다
# $? : 바로 앞 명령의 종료 코드 (0 이면 성공). RESULT=$(...) 바로 다음 줄이라서 jq 의 종료 코드가 들어 있다.
#      다른 명령을 하나라도 실행하면 값이 바뀌므로 바로 확인해야 한다.
# -ne : "같지 않다 (not equal)" 숫자 비교. 같은 계열: -eq 같다, -lt 작다, -le 작거나 같다, -gt 크다, -ge 크거나 같다.
#       [[ ]] 안에서 숫자는 이런 글자 연산자로, 문자열은 == 와 != 로 비교한다.
# -z "$RESULT" : 결과가 비어 있어도 (아무것도 출력하지 못했어도) 오류로 본다.
# ${FILES[*]} : 배열 원소를 공백으로 이어 한 줄로 보여 준다 (오류 메시지에 쓰려고).
if [[ $? -ne 0 || -z "$RESULT" ]]; then
    echo "[judge] 로그를 해석하지 못함 (JSON 형식이 깨졌을 수 있다): ${FILES[*]}" >&2
    exit 2
fi

# 검사 결과 줄들을 그대로 출력한다. 부른 쪽(러너)이 이 출력을 받아 사람이 읽기 좋게 바꿔 보여 준다.
echo "$RESULT"

# 실패한 검사가 하나라도 있으면 종료 코드 1
# grep -q '^FAIL' : ^ 는 줄의 시작. "FAIL 로 시작하는 줄이 있으면 성공" (-q 는 화면에 출력하지 않고 있는지만 확인).
# <<<"$RESULT" : 변수 내용을 grep 의 입력으로 준다 (here-string).
if grep -q '^FAIL' <<<"$RESULT"; then
    exit 1
fi
# 여기까지 왔다면 FAIL 줄이 없었다. 종료 코드 0 (전부 통과).
exit 0
