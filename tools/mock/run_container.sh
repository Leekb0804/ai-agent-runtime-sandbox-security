#!/bin/bash
#
# tools/mock/run_container.sh  -  가짜 agent-run (러너의 흐름을 테스트하려는 용도)
#
# 진짜 run_container.sh 와 같은 약속만 지킨다.
#   - 인자: agent-run -- /bin/sh -c "<스크립트>"
#   - MYC_SESSIONS_ROOT 아래에 세션 폴더를 만든다 (이 문자열이 있어야 러너의 사전 점검을 통과한다)
#   - "[*] 세션 시작: <세션ID> (cgroup_id=...)" 를 출력한다
# 로그 내용은 실제 로더 대신 tools/fixtures 의 4일차 실제 로그(이벤트와 판정)를 복사해서 만든다.
#
# MOCK_MODE (기본 normal):
#   normal : 스크립트에 trigger 가 있으면 s99 로그, 없으면 s00 로그를 만든다
#   wrong  : 일부러 반대 로그를 만든다 (러너가 FAIL 로 판정하는지 확인)
#   nolog  : 이벤트가 하나도 없는 세션 (로더가 아무것도 못 본 경우)
#   slow   : 이벤트를 0.3초 간격으로 한 줄씩 늦게 쓴다 (러너가 다 쓸 때까지 기다리는지 확인)
#   unattr : 세션 폴더 대신 _unattributed 에 쓴다 (by-cgroup 링크가 빠진 경우)

# 이 스크립트가 있는 폴더 기준으로 ../fixtures 로 이동해 절대 경로를 얻는다 (run_scenarios.sh 의 HERE 와 같은 관용구).
FIX="$(cd "$(dirname "$0")/../fixtures" && pwd)"
# ${변수:?메시지} : 변수가 비어 있거나 없으면 메시지를 오류로 출력하고 스크립트를 즉시 끝낸다.
# 진짜 run_container.sh 처럼 MYC_SESSIONS_ROOT 가 있어야만 동작하게 한다.
# (러너의 preflight 는 이 문자열이 run_container.sh 에 들어 있는지 grep 으로 확인한다.)
ROOT="${MYC_SESSIONS_ROOT:?MYC_SESSIONS_ROOT 가 필요하다}"
# ${*: -1} : 모든 인자($*) 중 마지막 하나. 러너가 sh -c 뒤에 스크립트를 마지막 인자로 넘기므로 이것이 시나리오 스크립트 문자열이다.
# (: 와 -1 사이의 공백이 필요하다.)
script="${*: -1}"                       # 마지막 인자가 스크립트
# date +%s%N : 현재 시각을 에폭 초와 나노초로 나타낸 숫자. 세션 ID 가 서로 겹치지 않게 한다.
sid="mock-$(date +%s%N)"

# 진짜 agent-run 과 같은 형식의 한 줄을 출력한다. 러너가 sed 로 세션 ID 를 뽑는 바로 그 줄이다.
echo "[*] 세션 시작: $sid (cgroup_id=1)"
# ${MOCK_MODE:-normal} : 환경변수가 없으면 normal.
mode="${MOCK_MODE:-normal}"

# 스크립트에 trigger 가 있으면 s99 의 실제 로그를, 아니면 s00 의 실제 로그를 쓴다
# [[ 문자열 == *trigger* ]] : 오른쪽을 따옴표 없이 쓰면 패턴이고 * 는 아무 글자이다.
# 스크립트 안에 trigger 가 들어 있으면 s99 시나리오로 보고 그 실제 로그를, 아니면 s00 의 실제 로그를 쓴다.
if [[ "$script" == *trigger* ]]; then
    src="$FIX/real_s99_dummy_block"
else
    src="$FIX/real_s00_benign"
fi
# wrong: 일부러 반대 로그를 쓴다
# wrong 모드 : 일부러 반대 로그를 고른다 (s99 로그였으면 s00 으로, 아니면 s99 로).
if [[ "$mode" == "wrong" ]]; then
    if [[ "$src" == *s99* ]]; then src="$FIX/real_s00_benign"; else src="$FIX/real_s99_dummy_block"; fi
fi

# 이 세션의 로그를 쓸 폴더 경로.
dest="$ROOT/$sid"
# [[ 조건 ]] && 명령 : 조건이 참이면 명령을 실행한다. unattr 모드에서는 세션 폴더 대신 _unattributed 에 쓴다.
# mkdir -p 는 폴더가 이미 있어도 오류 없이 넘어간다.
[[ "$mode" == "unattr" ]] && dest="$ROOT/_unattributed"
mkdir -p "$dest"

# case ... in 패턴) 명령 ;; ... esac : mode 값에 따라 분기한다 (run_scenarios.sh 의 옵션 처리와 같은 문법).
# 마지막의 *) 는 나머지 전부 (normal, wrong, unattr) 이다.
case "$mode" in
    # nolog : 아무것도 쓰지 않고 정상 종료한다 (세션 폴더만 있고 이벤트가 없다 = 로더가 아무것도 못 본 경우).
    nolog)
        exit 0 ;;
    # slow : 이벤트를 한 줄씩 0.3 초 간격으로 쓴다. 쓰기는 백그라운드에서 이어지고, 이 가짜 agent-run 은 바로 종료한다.
    #       그래서 러너는 "agent-run 은 끝났는데 로그는 아직 늘어나는 중"인 상황을 만나고,
    #       wait_settled 가 줄 수가 안정될 때까지 기다려 주는지가 실제로 시험된다.
    #       (이 분기 끝에서 wait 를 쓰면 가짜 agent-run 이 쓰기가 끝난 뒤에야 종료해서 이 시험이 무의미해진다.
    #        2026-10-07 에 wait 를 : 로 고쳤고, wait_settled 를 즉시 성공하게 망가뜨리면 이 테스트가 FAIL 하는 것을 확인했다.)
    slow)
        # 이벤트를 한 줄씩 늦게 쓴다. 판정 로그는 마지막 이벤트 직전에 완성한다
        # (러너는 이벤트 로그가 안정된 뒤에 판정을 읽으므로, 그때는 판정도 완성되어 있어야 한다)
        # mapfile -t lines <파일 : 파일의 각 줄을 배열 lines 에 한 줄씩 담는다 (-t 는 줄 끝의 개행을 지운다).
        mapfile -t lines <"$src/events.jsonl"
        # ( ... ) & : 괄호 안을 별도의 하위 쉘로, 백그라운드(&)에서 실행한다.
        # ${#lines[@]} 는 원소 개수, ${!lines[@]} 는 원소의 번호들 (0, 1, 2 ...) 이다.
        # 마지막 번호를 구해서, 마지막 이벤트를 쓰기 직전에 판정 로그를 복사해 둔다.
        # >> 는 파일 끝에 덧붙여 쓰기이다.
        (
            last=$(( ${#lines[@]} - 1 ))
            for i in "${!lines[@]}"; do
                [[ $i -eq $last ]] && cp "$src/verdicts.jsonl" "$dest/verdicts.jsonl"
                echo "${lines[$i]}" >>"$dest/events.jsonl"
                sleep 0.3
            done
        ) &
        # : : 아무 일도 하지 않는 쉘 내장 명령이다. 여기서 wait 를 쓰지 않는다는 표시이다
        #     (wait 는 백그라운드 작업이 끝날 때까지 기다리는 명령인데, 그러면 위 slow) 의 시험이 무의미해진다).
        #     그 결과 위의 백그라운드 쓰기는 이 스크립트가 끝난 뒤에도 계속된다.
        : ;;
    # normal, wrong, unattr : 선택된 로그(events, verdicts)를 그대로 복사한다.
    *)
        cp "$src/events.jsonl" "$dest/events.jsonl"
        cp "$src/verdicts.jsonl" "$dest/verdicts.jsonl" ;;
esac
# 정상 종료 (진짜 agent-run 이 시나리오를 마친 것과 같다).
exit 0
