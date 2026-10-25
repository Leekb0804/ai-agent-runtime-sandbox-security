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
#   killed : normal 처럼 로그를 쓰고, 세션이 cgroup.kill 로 죽은 것처럼 끝난다 (종료 코드 137, meta.json 에 exit_code 137)
#   live   : 러너 B안(live.json)용. 살아 있는 세션을 흉내 낸다 (아래 "live 모드" 참고)
# live 모드 환경변수 (MYC_CHECK_CGROUP_ROOT 와 MYC_CONTAINERS_ROOT 가 필요하다):
#   MOCK_LIVE=ok|noready|early|nokill|stale (기본 ok)
#     ok      : 가짜 세션 cgroup(MYC_CHECK_CGROUP_ROOT/mycontainer-<번호>)을 만들고 그 inode 를 cgroup_id 로 출력, 0.3초 뒤 준비 표시를 쓴다.
#               cgroup.kill 에 1 이 쓰이거나 host.sh 가 upper/mock_kill 을 만들면 로그와 meta.json(137)을 쓰고 137 로 끝난다
#     noready : 준비 표시를 쓰지 않는다 (신호를 받으면 ok 처럼 137 로 끝난다)
#     early   : 준비 표시 없이 0.3초 뒤 종료 코드 0 으로 끝난다
#     nokill  : 준비 표시를 쓰지만 신호를 받아도 끝나지 않는다 (최대 수명까지 산다)
#     stale   : 오래된(2000년) 준비 표시를 먼저 두고, 1초 뒤 upper/fresh_ready 를 만든 다음 새 준비 표시를 쓴다
#   MOCK_LIVE_READY=<경로>   : upper 기준 준비 표시 경로 (기본 tmp/myc_ready, live.json 의 ready 와 같아야 한다)
#   MOCK_LIVE_INODE=wrong    : 출력하는 cgroup_id 를 실제 inode 와 다르게 한다 (러너가 cgroup.kill 을 쓰지 않아야 한다)
#   MOCK_LIVE_MAX_S=N        : 가짜 세션의 최대 수명(초, 기본 45). 넘으면 종료 코드 99 로 끝난다
#   MOCK_LIVE_RECORD=<파일>  : 받은 신호를 한 줄씩 적는다 ("cgroup.kill 받음", "mock_kill 받음", nokill 이면 끝에 " (무시)")
#   MOCK_LIVE_DELAY_MS=N     : 신호를 받은 뒤 N 밀리초 더 살아 있다가 끝난다 (러너의 지연 측정 시험용, 기본 0)
#   MOCK_LIVE_TIMES=<파일>   : 끝나기 직전의 벽시계(epoch ms)를 "exit <ms>" 한 줄로 덧붙인다 (지연 측정 시험용)
# 런타임 검사(runtime.json) 시험용 환경변수:
#   MOCK_CGROUP_ID=N   : "세션 시작" 줄의 cgroup_id 값 (기본 1). 숫자가 아닌 값으로 "못 뽑는" 경우를 만든다
#   MOCK_META=missing  : killed 에서 meta.json 에 exit_code 를 쓰지 않는다.  MOCK_META=wrong : exit_code 를 0 으로 쓴다
#   MOCK_CG_LEFT=1     : MYC_CHECK_CGROUP_ROOT 아래에 mycontainer-<세션 번호> 디렉토리를 남긴다 (rmdir 실패를 흉내냄)
# rootfs 선택 시험용 환경변수:
#   MOCK_ENV_RECORD=<파일> : 불릴 때마다 받은 MYC_ROOTFS 를 그 파일에 한 줄 덧붙인다 ("MYC_ROOTFS=<값>", 해제돼 있으면 "MYC_ROOTFS 해제됨")

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

# MOCK_ENV_RECORD 가 있으면 러너가 넘긴 MYC_ROOTFS 를 기록한다 (러너가 시나리오마다 rootfs 를 고르는지 테스트가 확인한다)
if [[ -n "${MOCK_ENV_RECORD:-}" ]]; then
    # -v 이름 : 그 변수가 정해져 있으면 참이다 (빈 값도 정해진 것으로 본다. 해제와 빈 값을 구분하려는 것이다)
    if [[ -v MYC_ROOTFS ]]; then
        # 받은 값을 그대로 적는다
        echo "MYC_ROOTFS=$MYC_ROOTFS" >>"$MOCK_ENV_RECORD"
    else
        # 해제된 채로 불렸다
        echo "MYC_ROOTFS 해제됨" >>"$MOCK_ENV_RECORD"
    fi
fi
# live 모드: 러너 B안(live.json)의 흐름을 흉내 낸다. 살아 있는 동안 준비 표시를 쓰고, 종료 신호를 기다린다
if [[ "${MOCK_MODE:-normal}" == live ]]; then
    # 가짜 cgroup 루트 (러너가 cgroup_gone 검사와 정리에 쓰는 MYC_CHECK_CGROUP_ROOT). 없으면 진짜 /sys/fs/cgroup 을 건드리지 않도록 멈춘다
    cgr="${MYC_CHECK_CGROUP_ROOT:?live 모드에는 MYC_CHECK_CGROUP_ROOT 가 필요하다}"
    # 가짜 컨테이너 루트 (러너가 upper 를 찾는 곳)
    cont="${MYC_CONTAINERS_ROOT:?live 모드에는 MYC_CONTAINERS_ROOT 가 필요하다}"
    # 변형 (기본 ok)
    var="${MOCK_LIVE:-ok}"
    # 세션 번호 (세션 ID 끝 숫자)
    n="${sid##*-}"
    # 가짜 세션 cgroup 디렉터리
    cg="$cgr/mycontainer-$n"
    # 디렉터리를 만들고 빈 cgroup.kill 파일을 둔다 (러너의 정리가 여기에 1 을 쓴다)
    mkdir -p "$cg" && : >"$cg/cgroup.kill"
    # 디렉터리의 inode 가 cgroup_id 이다 (진짜 cgroup v2 와 같은 관계)
    ino="$(stat -c %i "$cg")"
    # wrong 이면 일부러 다른 값을 출력한다
    [[ "${MOCK_LIVE_INODE:-}" == wrong ]] && ino=$((ino + 1))
    # 가짜 upper 와 준비 표시 경로
    upper="$cont/mycontainer-$n/upper"
    # 준비 표시 경로 (live.json 의 ready 와 같은 값)
    ready="$upper/${MOCK_LIVE_READY:-tmp/myc_ready}"
    # 준비 표시가 들어갈 폴더를 만든다
    mkdir -p "$(dirname "$ready")"
    # stale 이면 세션 시작 줄보다 먼저 오래된 준비 표시를 둔다 (PID 재사용으로 남은 표시를 흉내 낸다)
    [[ "$var" == stale ]] && touch -d '2000-01-01 00:00:00' "$ready"
    # 진짜 agent-run 과 같은 형식의 세션 시작 줄
    echo "[*] 세션 시작: $sid (cgroup_id=$ino)"
    # 최대 수명 (0.02초 단위 횟수)
    max=$(( ${MOCK_LIVE_MAX_S:-45} * 50 ))
    # 변형별로 준비 표시를 쓴다
    case "$var" in
        # 준비 표시 없이 끝난다 (가짜 cgroup 은 진짜 run_container.sh 처럼 지운다)
        early) sleep 0.3; rm -f "$cg/cgroup.kill"; rmdir "$cg"; exit 0 ;;
        # 준비 표시를 쓰지 않는다
        noready) : ;;
        # 1초 뒤 새 표시를 쓴다는 사실을 먼저 남기고 새 표시를 쓴다 (host.sh 가 fresh_ready 를 보고 확인한다)
        stale) sleep 1; touch "$upper/fresh_ready"; touch "$ready" ;;
        # ok, nokill: 잠시 뒤 준비 표시를 쓴다
        *) sleep 0.3; touch "$ready" ;;
    esac
    # 종료 신호를 0.02초마다 최대 수명까지 기다린다 (러너의 지연 측정 시험이 이 간격만큼의 오차를 갖는다)
    got=0
    for ((i = 0; i < max; i++)); do
        # 러너의 정리가 cgroup.kill 에 1 을 썼는가
        if [[ "$(cat "$cg/cgroup.kill" 2>/dev/null)" == 1 ]]; then got="cgroup.kill 받음"
        # host.sh 가 신호 파일을 만들었는가 (진짜에서는 로더가 BLOCK 으로 cgroup.kill 을 쓰는 것에 해당한다)
        elif [[ -e "$upper/mock_kill" ]]; then got="mock_kill 받음"
        fi
        # 신호를 받았으면
        if [[ "$got" != 0 ]]; then
            # nokill 은 받은 사실만 한 번 적고 계속 산다
            if [[ "$var" == nokill ]]; then
                # 기록 파일이 있으면 적는다
                [[ -n "${MOCK_LIVE_RECORD:-}" ]] && echo "$got (무시)" >>"$MOCK_LIVE_RECORD"
                # 다시 적지 않도록 남은 수명 동안 그냥 기다린다
                sleep "$(( (max - i) / 50 ))"
                # 최대 수명이 지났다
                exit 99
            fi
            # 기록 파일이 있으면 적는다
            [[ -n "${MOCK_LIVE_RECORD:-}" ]] && echo "$got" >>"$MOCK_LIVE_RECORD"
            break
        fi
        # 0.02초 쉬고 다시 본다
        sleep 0.02
    done
    # 최대 수명 동안 신호가 없었다
    [[ "$got" == 0 ]] && exit 99
    # 지연 시험이면 신호 뒤에 정해진 시간만큼 더 산다 (밀리초를 sleep 의 초 단위 소수로 바꾼다)
    delay="${MOCK_LIVE_DELAY_MS:-0}"
    ((delay > 0)) && sleep "$(printf '%d.%03d' $((delay / 1000)) $((delay % 1000)))"
    # 스크립트에 trigger 가 있으면 s99 의 실제 로그, 아니면 s00 의 실제 로그를 쓴다 (다른 모드와 같은 규칙)
    if [[ "$script" == *trigger* ]]; then src="$FIX/real_s99_dummy_block"; else src="$FIX/real_s00_benign"; fi
    # 세션 폴더
    dest="$ROOT/$sid"
    # 폴더를 만든다
    mkdir -p "$dest"
    # 로그를 쓴다
    cp "$src/events.jsonl" "$dest/events.jsonl"
    # 판정 로그를 쓴다
    cp "$src/verdicts.jsonl" "$dest/verdicts.jsonl"
    # killed 모드와 같은 meta.json (종료 코드 137)
    jq -n --arg sid "$sid" --arg start "$(date -Is)" --arg cmd "$script" --arg end "$(date -Is)" \
        '{session_id:$sid, cgroup_id:1, started_at:$start, command:$cmd, ended_at:$end, exit_code:137}' >"$dest/meta.json"
    # 진짜 run_container.sh 처럼 세션 cgroup 을 지운다 (러너의 cgroup_gone 검사가 본다)
    rm -f "$cg/cgroup.kill"
    # 빈 디렉터리를 지운다
    rmdir "$cg"
    # 지연 시험이면 끝나기 직전의 벽시계를 남긴다 (EPOCHREALTIME 의 숫자만 남겨 마이크로초 정수로 만든 뒤 밀리초로)
    if [[ -n "${MOCK_LIVE_TIMES:-}" ]]; then us="${EPOCHREALTIME//[!0-9]/}"; echo "exit $((us / 1000))" >>"$MOCK_LIVE_TIMES"; fi
    # cgroup.kill 로 죽은 세션의 종료 코드
    exit 137
fi
# 진짜 agent-run 과 같은 형식의 한 줄을 출력한다. 러너가 sed 로 세션 ID 를 뽑는 바로 그 줄이다.
# cgroup_id 는 MOCK_CGROUP_ID 로 바꿀 수 있다 (기본 1)
echo "[*] 세션 시작: $sid (cgroup_id=${MOCK_CGROUP_ID:-1})"
# MOCK_CG_LEFT=1 이면 러너가 확인할 가짜 cgroup 루트 아래에 이 세션의 cgroup 디렉토리를 남긴다
if [[ "${MOCK_CG_LEFT:-0}" == 1 ]]; then
    # ${변수:?} : 루트가 지정되지 않았으면 진짜 /sys/fs/cgroup 에 만들지 않도록 여기서 멈춘다
    mkdir -p "${MYC_CHECK_CGROUP_ROOT:?MOCK_CG_LEFT 에는 MYC_CHECK_CGROUP_ROOT 가 필요하다}/mycontainer-${sid##*-}"
fi

# MYC_CONTAINERS_ROOT 가 있으면 진짜 agent-run 처럼 컨테이너 폴더(mycontainer-<세션 번호>/upper/tmp)를 만든다.
# 단 MOCK_NO_CONTAINER=1 이면 만들지 않는다 (컨테이너 폴더가 없는 경우를 재현하는 테스트용).
# 러너의 host.sh 스텝이 이 폴더를 찾는다. ${sid##*-} 는 세션 ID 에서 마지막 '-' 뒤만 남긴 것이다 (mock-<숫자> 이면 그 숫자).
if [[ -n "${MYC_CONTAINERS_ROOT:-}" && "${MOCK_NO_CONTAINER:-0}" != 1 ]]; then
    mkdir -p "$MYC_CONTAINERS_ROOT/mycontainer-${sid##*-}/upper/tmp"
fi
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
# killed : 진짜 run_container.sh 가 kill 된 세션 뒤에 하는 일을 흉내 낸다.
#          meta.json 에 시작 필드와 끝 필드(ended_at, exit_code)를 쓰고 137 로 끝난다 (run_container.sh 의 jq 와 같은 필드).
if [[ "$mode" == "killed" ]]; then
    # 기록할 exit_code. MOCK_META=wrong 이면 일부러 다른 값(0)
    meta_rc=137
    [[ "${MOCK_META:-}" == wrong ]] && meta_rc=0
    # 시작 때 쓰는 필드 (session_id, cgroup_id, started_at, command)
    jq -n --arg sid "$sid" --arg start "$(date -Is)" --arg cmd "$script" \
        '{session_id:$sid, cgroup_id:1, started_at:$start, command:$cmd}' >"$dest/meta.json"
    # MOCK_META=missing 이 아니면 끝날 때의 필드를 덧붙인다
    if [[ "${MOCK_META:-}" != missing ]]; then
        # 같은 파일을 읽고 쓰지 않도록 임시 파일을 거친다
        jq --arg end "$(date -Is)" --argjson rc "$meta_rc" '. + {ended_at:$end, exit_code:$rc}' "$dest/meta.json" >"$dest/meta.json.tmp"
        mv "$dest/meta.json.tmp" "$dest/meta.json"
    fi
    # cgroup.kill 로 죽은 세션의 종료 코드 (128 + SIGKILL 9)
    exit 137
fi
# 정상 종료 (진짜 agent-run 이 시나리오를 마친 것과 같다).
exit 0
