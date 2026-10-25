#!/bin/bash
#
# tools/test_live_latency.sh  -  B안 지연 도구(tools/live_latency.sh)의 로그 파서와 요약 시험
#
# sudo 없이 돈다. 고정 fixture 로그(아래에서 직접 쓴다)로 parts 가 HIT 시각과 kill 요청 시각을 바르게 읽는지,
# 기록이 없거나 깨졌으면 n/a 를 내는지, summary 가 개수, 최소, 중앙값, 최대를 바르게 내는지 본다.
#
# 사용법: tools/test_live_latency.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u
# 이 파일이 있는 폴더
HERE="$(cd "$(dirname "$0")" && pwd)"
# 시험 대상
LL="$HERE/live_latency.sh"
# 시험용 임시 폴더 (끝나면 지운다)
T="$(mktemp -d)"
# 끝날 때 임시 폴더를 지운다
trap 'rm -rf "$T"' EXIT
# 실패 수
failures=0

# 출력이 기대와 글자 그대로 같은지 본다. 인자: 설명, 기대, 실제
same() {
    # 같으면 통과
    if [[ "$3" == "$2" ]]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n        기대: %q\n        실제: %q\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}

# 세션 폴더 하나를 만든다. 인자: 폴더, HIT 시각(빈 값이면 TAG_HIT 없음), kill 시각(빈 값이면 kill 대응 없음)
# 실제 로더의 기록 모양(jsonl.c)을 따른다: events.jsonl 에 event, verdicts.jsonl 에 verdict 와 action
mk_sess() {
    # 인자
    local d="$1" hit="$2" kill="$3"
    # 폴더를 만든다
    mkdir -p "$d"
    # 이벤트: 앞에 EXEC 하나(무시되어야 함), 그 뒤 TAG_HIT (있을 때만)
    {
        echo '{"schema_version":0,"type":"event","session":"s-1","logged_at_ms":1000050,"event":{"kind":"EXEC","pid":10,"cgroup_id":7,"ts_ns":1,"filename":"/bin/sh"}}'
        [[ -n "$hit" ]] && echo '{"schema_version":0,"type":"event","session":"s-1","logged_at_ms":'"$hit"',"event":{"kind":"TAG_HIT","pid":11,"cgroup_id":7,"ts_ns":2,"exec_cgroup_id":1,"tag_ts_ns":1,"tag_write_count":1,"dev":1,"ino":2,"filename":"/x/tmp/payload"}}'
    } >"$d/events.jsonl"
    # 판정과 대응: BLOCK 판정(무시되어야 함), 그 뒤 kill 대응 (있을 때만)
    {
        echo '{"schema_version":0,"type":"verdict","session":"s-1","logged_at_ms":1000120,"level":"BLOCK","detector":"write_exec_boundary","reason":"r","event":{"kind":"TAG_HIT","pid":11,"cgroup_id":7,"ts_ns":2}}'
        [[ -n "$kill" ]] && echo '{"schema_version":0,"type":"action","session":"s-1","logged_at_ms":'"$kill"',"cgroup_id":7,"action":"kill","result":"sent","detail":"written","errno":0,"reason":"r"}'
    } >"$d/verdicts.jsonl"
    # 함수가 마지막 && 의 거짓에 끌려가지 않게 성공으로 끝낸다
    return 0
}

# 탭 하나
TAB=$'\t'

echo "[parts: 로그 파서]"
# 기본: t0=1000000, HIT=1000100, kill=1000130, t1=1000200 -> 전체 200, 실행→HIT 100, HIT→kill 30, kill→종료 70
mk_sess "$T/ok" 1000100 1000130
same "HIT 과 kill 이 있으면 세 구간 (200, 100, 30, 70)" "200${TAB}100${TAB}30${TAB}70" "$("$LL" parts "$T/ok" 1000000 1000200)"
# TAG_HIT 이 두 번이면 첫 기록을 쓴다
mk_sess "$T/two" 1000100 1000130
echo '{"schema_version":0,"type":"event","session":"s-1","logged_at_ms":1000180,"event":{"kind":"TAG_HIT","pid":12,"cgroup_id":7,"ts_ns":3}}' >>"$T/two/events.jsonl"
same "TAG_HIT 이 둘이면 첫 기록 (130, 90, 30, 10)" "130${TAB}90${TAB}30${TAB}10" "$("$LL" parts "$T/two" 1000010 1000140)"
# HIT 이 없으면 구간은 n/a, 전체는 낸다
mk_sess "$T/nohit" "" 1000130
same "TAG_HIT 기록이 없으면 구간은 n/a" "200${TAB}n/a${TAB}n/a${TAB}n/a" "$("$LL" parts "$T/nohit" 1000000 1000200)"
# kill 대응이 없으면 n/a
mk_sess "$T/nokill" 1000100 ""
same "kill 대응 기록이 없으면 구간은 n/a" "200${TAB}n/a${TAB}n/a${TAB}n/a" "$("$LL" parts "$T/nokill" 1000000 1000200)"
# 세션 폴더에 로그 파일이 없으면 n/a
mkdir -p "$T/empty"
same "로그 파일이 없으면 구간은 n/a" "200${TAB}n/a${TAB}n/a${TAB}n/a" "$("$LL" parts "$T/empty" 1000000 1000200)"
# JSON 이 깨졌으면 n/a (실패로 끝나지 않는다)
mk_sess "$T/broken" 1000100 1000130
echo '{"type":"event",' >>"$T/broken/events.jsonl"
same "로그 JSON 이 깨졌으면 구간은 n/a" "200${TAB}n/a${TAB}n/a${TAB}n/a" "$("$LL" parts "$T/broken" 1000000 1000200)"
# t0 이 숫자가 아니면 전체도 n/a
same "t0 이 숫자가 아니면 전체도 n/a" "n/a${TAB}n/a${TAB}n/a${TAB}n/a" "$("$LL" parts "$T/ok" abc 1000200)"
# 종료 코드는 언제나 0 이다 (판정에 영향을 주지 않는다)
"$LL" parts "$T/empty" 1 2 >/dev/null; rc=$?
same "parts 는 기록이 없어도 종료 코드 0" "0" "$rc"

echo "[summary: 요약]"
# 홀수 개: 5, 1, 3 -> 최소 1, 중앙값 3, 최대 5. 구간 열 하나는 전부 n/a
printf '1\ts\t5\t10\tn/a\t1\n2\ts\t1\t30\tn/a\t2\n3\ts\t3\t20\tn/a\t3\n' >"$T/odd.tsv"
out="$("$LL" summary "$T/odd.tsv")"
same "머리 줄에 횟수" "지연 요약 (B안, 3회)" "$(sed -n 1p <<<"$out")"
same "전체 열 (홀수 개)" "  전체: 최소 1, 중앙값 3, 최대 5 ms (3개)" "$(sed -n 2p <<<"$out")"
same "실행→HIT 열" "  실행→HIT: 최소 10, 중앙값 20, 최대 30 ms (3개)" "$(sed -n 3p <<<"$out")"
same "전부 n/a 인 열" "  HIT→kill 요청: n/a (0개)" "$(sed -n 4p <<<"$out")"
same "kill 요청→종료 열" "  kill 요청→종료: 최소 1, 중앙값 2, 최대 3 ms (3개)" "$(sed -n 5p <<<"$out")"
# 짝수 개와 n/a 섞임: 10, 1, n/a, 3, 2 -> 숫자 1, 2, 3, 10 -> 중앙값 (2+3)/2 = 2 (버림)
printf '1\ts\t10\tn/a\tn/a\tn/a\n2\ts\t1\tn/a\tn/a\tn/a\n3\ts\tn/a\tn/a\tn/a\tn/a\n4\ts\t3\tn/a\tn/a\tn/a\n5\ts\t2\tn/a\tn/a\tn/a\n' >"$T/even.tsv"
out="$("$LL" summary "$T/even.tsv")"
same "짝수 개면 가운데 둘의 평균(버림), n/a 는 뺌" "  전체: 최소 1, 중앙값 2, 최대 10 ms (4개)" "$(sed -n 2p <<<"$out")"

echo "[사용 오류]"
# 인자가 모자라면 2
"$LL" parts "$T/ok" 1 >/dev/null 2>&1; rc=$?
same "parts 인자가 모자라면 rc 2" "2" "$rc"
"$LL" nosuch >/dev/null 2>&1; rc=$?
same "모르는 하위 명령이면 rc 2" "2" "$rc"

echo
# 마지막: 실패한 케이스가 없으면 종료 코드 0, 있으면 1.
if [[ $failures -eq 0 ]]; then
    echo "ALL PASSED (실패 0)"
    exit 0
fi
echo "FAILED (실패 $failures)"
exit 1
