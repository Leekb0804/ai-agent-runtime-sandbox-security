#!/bin/bash
#
# tools/live_latency.sh  -  러너 B안(live.json)의 지연 내역 계산과 요약
#
# 러너가 B안 시나리오마다 부른다. PASS/FAIL 판정에는 쓰지 않는다 (출력만 한다).
#
#   parts <세션 폴더> <t0_ms> <t1_ms>
#       t0 = 러너가 host.sh 를 실행하기 직전, t1 = 러너가 agent-run 이 없어진 것을 처음 확인한 순간 (둘 다 벽시계 epoch ms)
#       세션 로그에서 HIT 시각과 kill 요청 시각을 읽어 탭으로 구분한 네 값을 한 줄로 낸다:
#         전체(t1-t0)  실행→HIT(HIT-t0)  HIT→kill 요청(kill-HIT)  kill 요청→종료(t1-kill)
#       HIT 시각  : events.jsonl 의 첫 {"type":"event", event.kind == "TAG_HIT"} 기록의 logged_at_ms
#       kill 요청 : verdicts.jsonl 의 첫 {"type":"action", "action":"kill"} 기록의 logged_at_ms
#       logged_at_ms 는 로더가 기록을 "쓴" 시각이다 (src/loader/jsonl.c 의 now_ms, CLOCK_REALTIME).
#       둘 중 하나라도 없거나 읽지 못하면 세 구간은 모두 n/a 이고 전체만 낸다. 종료 코드는 언제나 0 이다
#   summary <latency.tsv>
#       러너가 --repeat 에서 남긴 표(라운드, 이름, 전체, 실행→HIT, HIT→kill 요청, kill 요청→종료)를 읽어
#       열마다 개수, 최소, 중앙값, 최대를 낸다. n/a 는 그 열의 계산에서 뺀다.
#       중앙값은 정렬한 뒤 가운데 값이고, 개수가 짝수면 가운데 두 값의 평균(소수점 아래 버림)이다

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u

# 정수(음수 포함)인가
is_num() { [[ "${1-}" =~ ^-?[0-9]+$ ]]; }

# parts: 세 구간을 계산한다
cmd_parts() {
    # 인자: 세션 폴더, t0, t1
    local sdir="$1" t0="$2" t1="$3" hit kill total="n/a"
    # 전체: 둘 다 정수일 때만
    if is_num "$t0" && is_num "$t1"; then total=$((t1 - t0)); fi
    # HIT 시각: 첫 TAG_HIT 이벤트 기록. 파일이 없거나 JSON 이 깨지면 빈 값
    hit="$(jq -rs '[.[] | select(.type == "event" and .event.kind == "TAG_HIT") | .logged_at_ms] | first // empty' "$sdir/events.jsonl" 2>/dev/null)"
    # kill 요청 시각: 첫 kill 대응 기록
    kill="$(jq -rs '[.[] | select(.type == "action" and .action == "kill") | .logged_at_ms] | first // empty' "$sdir/verdicts.jsonl" 2>/dev/null)"
    # 하나라도 없으면 구간은 모두 n/a
    if ! is_num "$hit" || ! is_num "$kill" || ! is_num "$t0" || ! is_num "$t1"; then
        # 전체와 세 구간
        printf '%s\tn/a\tn/a\tn/a\n' "$total"
        return 0
    fi
    # 전체, 실행→HIT, HIT→kill 요청, kill 요청→종료
    printf '%s\t%s\t%s\t%s\n' "$total" "$((hit - t0))" "$((kill - hit))" "$((t1 - kill))"
}

# summary 의 한 열: 숫자만 모아 개수, 최소, 중앙값, 최대를 낸다. 인자: 열 이름, 값들
col_stats() {
    # 열 이름
    local label="$1" v n mid med
    shift
    # 숫자만 모은다 (n/a 는 뺀다)
    local nums=()
    for v in "$@"; do is_num "$v" && nums+=("$v"); done
    # 하나도 없으면 n/a
    n=${#nums[@]}
    if ((n == 0)); then printf '  %s: n/a (0개)\n' "$label"; return 0; fi
    # 오름차순 정렬
    mapfile -t nums < <(printf '%s\n' "${nums[@]}" | sort -n)
    # 가운데 위치
    mid=$((n / 2))
    # 홀수면 가운데, 짝수면 가운데 둘의 평균 (bash 정수 나눗셈은 0 쪽으로 버린다)
    if ((n % 2 == 1)); then med="${nums[$mid]}"; else med=$(( (nums[mid - 1] + nums[mid]) / 2 )); fi
    # 한 줄로 낸다
    printf '  %s: 최소 %s, 중앙값 %s, 최대 %s ms (%s개)\n' "$label" "${nums[0]}" "$med" "${nums[-1]}" "$n"
}

# summary: latency.tsv 를 열마다 요약한다
cmd_summary() {
    # 표 파일
    local f="$1" r name t a b c rows=0
    # 파일이 없으면 할 일이 없다
    [[ -f "$f" ]] || { echo "[live_latency] 표가 없다: $f" >&2; return 0; }
    # 열마다 값을 모은다
    local T=() A=() Bv=() C=()
    while IFS=$'\t' read -r r name t a b c; do
        # 줄 수
        rows=$((rows + 1))
        # 열별로 담는다
        T+=("$t"); A+=("$a"); Bv+=("$b"); C+=("$c")
    done <"$f"
    # 머리 줄
    echo "지연 요약 (B안, ${rows}회)"
    # 전체와 세 구간
    col_stats "전체" "${T[@]}"
    col_stats "실행→HIT" "${A[@]}"
    col_stats "HIT→kill 요청" "${Bv[@]}"
    col_stats "kill 요청→종료" "${C[@]}"
}

# 하위 명령으로 나눈다
case "${1:-}" in
    # 세 구간
    parts) [[ $# -eq 4 ]] || { echo "사용법: $0 parts <세션 폴더> <t0_ms> <t1_ms>" >&2; exit 2; }; cmd_parts "$2" "$3" "$4" ;;
    # 요약
    summary) [[ $# -eq 2 ]] || { echo "사용법: $0 summary <latency.tsv>" >&2; exit 2; }; cmd_summary "$2" ;;
    # 그 밖은 사용 오류
    *) echo "사용법: $0 parts <세션 폴더> <t0_ms> <t1_ms> | summary <latency.tsv>" >&2; exit 2 ;;
esac
