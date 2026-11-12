#!/bin/bash
set -e

# 소스나 loader_lock.h 가 바뀌었거나 바이너리가 없으면 재컴파일
if [[ ! -x ./mycontainer_run || mycontainer_run.c -nt ./mycontainer_run || loader/loader_lock.h -nt ./mycontainer_run ]]; then
    echo "[*] mycontainer_run.c 컴파일 중..."
    gcc -Wall -o mycontainer_run mycontainer_run.c -lbpf
fi

MEMORY="max"
CPU="max"
PIDS="max"
# rootfs(overlay 의 lowerdir, 이미지 레이어). 기본은 busybox rootfs, 환경변수 MYC_ROOTFS 가 비어 있지 않으면 그 경로를 쓴다
# sudo 는 환경변수를 지우므로 sudo env MYC_ROOTFS=경로 ./run_container.sh 형태로 넘긴다
ROOTFS_PATH="${MYC_ROOTFS:-/home/dev/practice/mycontainer/busybox_rootfs}"
CONTAINER_DIR="/var/lib/mycontainer/containers/mycontainer-$$"  # upper/work/merged를 담을 디렉토리
CMD=()
MODE="run"
SESSION_ID=""
SESSION_DIR=""
# 시작 표시 파일 경로 (agent 모드에서 세션 폴더의 started). mycontainer_run 이 clone 성공 뒤 만든다. 없으면 정리 단계가 started:false 를 쓴다
START_MARK=""
CGROUP_ID=""
# 정리 단계가 부분 생성 상태를 구분하는 데 쓴다. NETNS_NAME 은 netns 를 만들기 직전에 정해진다
NETNS_NAME=""
# mycontainer_run 을 띄웠는지 (띄우기 전에는 감시 맵에 등록될 수 없으므로 맵 삭제를 하지 않는다)
MC_STARTED=0
# 감시 맵의 pin 경로. mycontainer_run.c 의 SESSION_CGROUPS_PIN 과 같은 값이어야 한다 (mycontainer_run 이 이 맵에 세션 cgroup 을 등록한다)
SESSION_CGROUPS_PIN="/sys/fs/bpf/session_cgroups"
# meta.json 형식 버전. 로그의 LOG_SCHEMA_VERSION(src/loader/jsonl.h)과 함께 올린다 (자동 연결은 없다)
META_SCHEMA_VERSION=1

# cgroup id(10진수)를 bpftool 의 "key hex" 뒤에 줄 8바이트 리틀엔디안 hex 로 바꿔 출력한다 (예: 478322 -> 72 4c 07 00 00 00 00 00)
# run_scenarios.sh 의 map_entry_gone 검사와 같은 방식이다 (그쪽은 bpftool -j 의 JSON 배열 모양을 만들어서 함수를 같이 쓰지 않는다)
# 숫자가 아니면 아무것도 출력하지 않고 1 을 돌려준다 (printf 는 숫자가 아니면 0 을 내므로 엉뚱한 키가 된다)
cgroup_id_key_hex() {
    # hex 는 16자리 16진수, b 는 바이트 번호, out 은 결과
    local hex b out=""
    # 10진수 숫자만 받는다
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    # 16자리 16진수 (8바이트, 앞을 0 으로 채운다)
    hex="$(printf '%016x' "$1")" || return 1
    # 마지막 두 자리(가장 낮은 바이트)부터 앞으로 간다
    for ((b = 7; b >= 0; b--)); do
        # ${hex:시작:길이} 로 두 글자씩 자른다
        out+="${hex:$((b * 2)):2}"
        # 마지막 바이트가 아니면 공백으로 나눈다 (bpftool 이 바이트마다 인자 하나를 받는다)
        if ((b > 0)); then out+=" "; fi
    done
    # 결과를 출력한다
    echo "$out"
}

# 감시 맵에서 이 세션의 cgroup 항목을 지운다.
# 외부 cgroup.kill, 등록 뒤의 die, kill -9 처럼 mycontainer_run 이 종료 때의 삭제를 못 하고 죽은 경우를 위한 것이다.
# 정상 종료와 로더 kill(sent) 경로에서는 이미 지워져 있어 lookup 이 Not found(254)로 끝나고 아무것도 출력하지 않는다.
# 어떤 경우에도 스크립트를 멈추거나 RC 를 바꾸지 않는다 (명령은 모두 if 나 || 안에서 부른다).
unwatch_session_cgroup() {
    # key 는 리틀엔디안 hex, lrc 는 lookup 의 종료 코드, lerr 는 lookup 의 오류 출력
    local key lrc lerr
    # cgroup id 를 모르면 지울 키가 없다
    if [[ -z "$CGROUP_ID" ]]; then
        echo "[!] 감시 맵 정리 건너뜀: cgroup_id 를 모름 ($CGROUP_PATH, 계속 진행)"
        return 0
    fi
    # 숫자가 아니면 키를 만들 수 없다
    if ! key="$(cgroup_id_key_hex "$CGROUP_ID")"; then
        echo "[!] 감시 맵 정리 건너뜀: cgroup_id 가 숫자가 아님 ($CGROUP_ID, 계속 진행)"
        return 0
    fi
    # 지운다. 결과는 보지 않는다 (이미 없으면 Not found 이고, 판정은 아래 lookup 으로 한다). $key 는 공백으로 나뉘어 8개 인자가 된다
    sudo bpftool map delete pinned "$SESSION_CGROUPS_PIN" key hex $key > /dev/null 2>&1 || true
    # 같은 키를 다시 찾아 판정한다. 오류 출력만 변수에 받고, 종료 코드는 || 로 받는다 (set -e 로 끝나지 않게)
    lrc=0
    lerr="$(sudo bpftool map lookup pinned "$SESSION_CGROUPS_PIN" key hex $key 2>&1 > /dev/null)" || lrc=$?
    case "$lrc" in
        # Not found: 항목이 없다 (정상)
        254) ;;
        # 찾았다: 삭제 뒤에도 남아 있다. 손으로 지울 수 있게 키를 같이 알린다
        0) echo "[!] 감시 맵 정리 실패: cgroup_id $CGROUP_ID 항목이 삭제 뒤에도 남음 ($SESSION_CGROUPS_PIN key hex $key, 계속 진행)" ;;
        # 그 밖(맵을 열지 못함 255, bpftool 을 찾지 못함 등): 남았는지 알 수 없다
        *) echo "[!] 감시 맵 정리 확인 불가: bpftool lookup rc=$lrc ${lerr:0:200} ($SESSION_CGROUPS_PIN key hex $key, 계속 진행)" ;;
    esac
}

# 세션 정리 단계. mycontainer_run 이 돌아온 뒤 정상 경로가 부르고, TERM/INT 처리기(on_signal)도 부른다. 마지막에 RC 로 끝낸다.
# 순서: 감시 맵 항목 삭제 -> cgroup rmdir 재시도 -> netns 삭제 -> (agent 모드) 시작 표시 확인 -> meta.json 갱신 -> exit "$RC"
# 맵 삭제는 반드시 rmdir 전에 한다. rmdir 뒤에는 cgroup id 가 다른 세션에 재사용될 수 있어 그 id 로 지우면 남의 감시가 풀린다.
# 설정 단계 도중(부분 생성 상태)에 불릴 수 있으므로 있는 자원만 정리한다. set -e 가 살아 있으니 실패할 수 있는 명령은 if 나 || 안에서 부른다.
cleanup_session() {
    # 정리 중에 TERM/INT 가 또 와서 정리가 두 번 돌지 않게 무시로 바꾼다 (정상 경로도 같다)
    trap '' TERM INT

    # mycontainer_run 을 띄운 뒤에만 맵 항목이 있을 수 있다 (그 전이면 지울 것도, 알릴 것도 없다)
    if [[ $MC_STARTED -eq 1 ]]; then
        unwatch_session_cgroup
    fi

    # cgroup 디렉토리 정리는 짧게 다시 시도한다.
    # kill(cgroup.kill) 직후에는 mycontainer_run 이 먼저 죽어서 여기로 돌아왔는데도 cgroup 안의 다른 프로세스가
    # 아직 종료 중일 수 있다. 그러면 rmdir 이 EBUSY 로 실패한다. 이 디렉토리를 지워 줄 다른 주체가 없으므로 여기서 기다린다.
    # 정상 종료 경로에서는 첫 시도에 성공하므로 지연이 없다.
    # 최대 시도 횟수와 간격(초)
    RMDIR_TRIES=20
    RMDIR_INTERVAL=0.05
    # 마지막 시도의 오류 메시지 (실패했을 때만 보여 준다)
    rmdir_err=""
    # 지웠는지 표시
    rmdir_ok=0
    # cgroup 디렉토리가 없으면(만들기 전이나 만드는 도중에 신호가 왔으면) 재시도와 경고를 건너뛴다
    if [[ -d "$CGROUP_PATH" ]]; then
        # 1번째부터 RMDIR_TRIES 번째까지 시도한다
        for ((i = 1; i <= RMDIR_TRIES; i++)); do
            # if 조건 안이라 실패해도 set -e 로 끝나지 않는다. 오류 출력은 변수에 받아 둔다
            if rmdir_err="$(sudo rmdir "$CGROUP_PATH" 2>&1)"; then
                # 성공하면 즉시 빠져나온다
                rmdir_ok=1
                break
            fi
            # 마지막 시도가 아니면 잠깐 쉬고 다시 시도한다
            if [[ $i -lt $RMDIR_TRIES ]]; then
                sleep "$RMDIR_INTERVAL"
            fi
        done
        # 끝까지 실패하면 예전처럼 경고만 내고 계속 진행한다 (종료 코드, netns 삭제, meta.json 기록은 그대로)
        if [[ $rmdir_ok -ne 1 ]]; then
            # 예전에는 rmdir 자신의 오류가 stderr 에 그대로 나왔으므로 마지막 오류를 같은 곳에 낸다
            echo "$rmdir_err" >&2
            # 경고에 시도 횟수를 덧붙인다
            echo "[!] cgroup 정리 실패: $CGROUP_PATH (${RMDIR_TRIES}회 시도, 계속 진행)"
        fi
    fi
    # netns 이름이 정해지기 전에 신호가 왔으면 지울 netns 가 없다
    if [[ -n "$NETNS_NAME" ]]; then
        sudo ip netns delete "$NETNS_NAME" || echo "[!] netns 정리 실패: $NETNS_NAME (계속 진행)"
    fi

    # 컨테이너가 시작됐는지 (agent 모드에서 시작 표시 파일이 있으면 true). 세션 폴더가 생기기 전이면 판정하지 않는다
    local started=false
    if [[ "$MODE" == "agent" && -n "$SESSION_DIR" ]]; then
        # 표시 파일은 mycontainer_run 이 clone 성공 뒤에 만든다
        if [[ -n "$START_MARK" && -f "$START_MARK" ]]; then
            started=true
        else
            # 거부(로더 없음, 감시 맵 열기·등록 실패, cgroup 합류 실패 등)이거나 컨테이너를 만들기 전에 끝났다. 세션 폴더는 지우지 않는다
            echo "[!] 세션 시작 거부: 컨테이너가 시작되지 않음 ($SESSION_ID, 종료 코드 $RC, 시작 표시 없음: $START_MARK)"
        fi
    fi

    # meta.json 은 있을 때만 갱신한다 (없는데 jq 가 실패하고 tee 만 성공하면 빈 meta.json 이 생긴다)
    if [[ "$MODE" == "agent" && -n "$SESSION_DIR" && -f "$SESSION_DIR/meta.json" ]]; then
        # jq 의 결과를 변수에 먼저 받는다. 파이프로 바로 쓰면 pipefail 이 없어서 jq 가 실패해도 tee 가 빈 임시 파일을 만들고 그것이 meta.json 을 덮어쓴다
        # if 조건 안이라 jq 가 실패해도 set -e 로 끝나지 않는다. jq 의 오류 메시지는 숨기지 않고 그대로 화면에 낸다
        local new_meta
        # meta.json 은 0600 root 소유라 sudo 로 읽는다
        if new_meta="$(sudo jq --arg end "$(date -Is)" --argjson rc "$RC" --argjson started "$started" \
               '. + {ended_at:$end, exit_code:$rc, started:$started}' "$SESSION_DIR/meta.json")" && [[ -n "$new_meta" ]]; then
            # 새 내용을 임시 파일에 쓰고, 쓰기가 성공했을 때만 바꿔 넣는다 (파이프 대신 here-string)
            # 0600: mv 로 바꿔 넣으면 임시 파일의 권한이 meta.json 의 권한이 되므로, 쓰기 전에 임시 파일을 만들고 600 으로 맞춘다
            # (이미 있는 임시 파일도 chmod 로 맞춰진다. touch 나 chmod 가 실패하면 아래 "쓰기" 실패 분기로 가서 meta.json 은 그대로 둔다)
            if sudo touch "$SESSION_DIR/meta.json.tmp" \
                && sudo chmod 600 "$SESSION_DIR/meta.json.tmp" \
                && sudo tee "$SESSION_DIR/meta.json.tmp" > /dev/null <<< "$new_meta"; then
                # 바꿔 넣기가 실패해도 정리를 멈추지 않고 RC 로 끝낸다
                sudo mv "$SESSION_DIR/meta.json.tmp" "$SESSION_DIR/meta.json" || echo "[!] meta.json 갱신 실패 (이동): $SESSION_DIR/meta.json (계속 진행)"
            else
                # 임시 파일을 쓰지 못했다. meta.json 은 그대로 둔다
                echo "[!] meta.json 갱신 실패 (쓰기): $SESSION_DIR/meta.json.tmp (계속 진행)"
            fi
        else
            # jq 가 실패했거나 출력이 비었다. meta.json 은 손대지 않는다 (exit_code 가 기록되지 않은 채로 남는다)
            echo "[!] meta.json 갱신 실패 (jq): $SESSION_DIR/meta.json 을 그대로 둠 (계속 진행)"
        fi
    fi

    exit "$RC"
}

# TERM/INT 처리기. 인자는 종료 코드(TERM 143, INT 130)이고 meta.json 의 exit_code 에도 이 값이 들어간다.
# 시간 초과(timeout 이 프로세스 그룹에 TERM)나 Ctrl-C 에서 mycontainer_run 은 같은 신호로 죽지만 컨테이너 PID 1 은
# PID 네임스페이스 init 이라 살아남는다. 세션 cgroup 에 cgroup.kill 을 써서 남은 프로세스를 모두 끝낸 뒤 정리 단계를 탄다.
# 이 bash 는 세션 cgroup 밖이라 cgroup.kill 에 같이 죽지 않는다 (mycontainer_run 이 자기 자신만 합류시킨다).
# 한계: 신호가 그룹이 아니라 이 bash 에만 오면 bash 는 전경 자식(mycontainer_run)이 끝날 때까지 이 처리기를 미룬다.
on_signal() {
    # 정리 중에 신호가 또 와서 처리기와 정리가 두 번 돌지 않게 무시로 바꾼다
    trap '' TERM INT
    # 이 세션의 종료 코드
    RC="$1"
    # 세션 cgroup 이 있을 때만 그 안의 프로세스를 모두 끝낸다 (실패해도 정리는 계속한다)
    if [[ -d "$CGROUP_PATH" ]]; then
        echo 1 | sudo tee "$CGROUP_PATH/cgroup.kill" > /dev/null || echo "[!] cgroup.kill 쓰기 실패: $CGROUP_PATH (계속 진행)"
    fi
    # 정리 단계 (함수 안의 exit "$RC" 로 끝난다)
    cleanup_session
}


if [[ "$1" == "run" ]]; then
    shift
elif [[ "$1" == "agent-run" ]]; then
    MODE="agent"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --memory=*) MEMORY="${1#*=}"; shift ;;
        --cpu=*) CPU="${1#*=}"; shift ;;
        --pids=*) PIDS="${1#*=}"; shift ;;
        --)
            shift
            CMD=("$@")
            break
            ;;
        *) ROOTFS_PATH="$1"; shift ;;
    esac
done

# MYC_ROOTFS 로 rootfs 를 바꿨으면 컨테이너를 만들기 전에 검사한다 (fail-closed). 하나라도 틀리면 이유 한 줄을 내고 끝낸다
if [[ -n "${MYC_ROOTFS:-}" ]]; then
    # (a) 절대 경로여야 한다 (상대 경로는 실행 위치에 따라 다른 폴더를 가리킨다)
    if [[ "$ROOTFS_PATH" != /* ]]; then
        # 어느 검사가 왜 틀렸는지 알린다
        echo "[!] rootfs 검사 실패 (절대 경로 아님): $ROOTFS_PATH" >&2
        # cgroup, 세션 폴더, netns 를 만들기 전이라 되돌릴 것이 없다
        exit 1
    fi
    # (b) 디렉터리여야 한다 (없는 경로나 파일이면 overlay 마운트가 실패한다)
    if [[ ! -d "$ROOTFS_PATH" ]]; then
        # 어느 검사가 왜 틀렸는지 알린다
        echo "[!] rootfs 검사 실패 (디렉터리가 없음): $ROOTFS_PATH" >&2
        # 컨테이너를 만들기 전에 끝낸다
        exit 1
    fi
    # (c) dev/null 이 문자 장치로 있어야 한다 (mycontainer_run 4.7단계가 이 노드 위에 호스트 /dev/null 을 bind mount 한다)
    if [[ ! -c "$ROOTFS_PATH/dev/null" ]]; then
        # 어느 검사가 왜 틀렸는지 알린다
        echo "[!] rootfs 검사 실패 (dev/null 문자 장치가 없음): $ROOTFS_PATH/dev/null" >&2
        # 컨테이너를 만들기 전에 끝낸다
        exit 1
    fi
fi
# 어떤 rootfs 를 쓰는지 알린다 (MYC_ROOTFS 가 있으면 그 값이고 검사를 통과했다)
echo "[*] rootfs: $ROOTFS_PATH"

if [[ "$CPU" == "max" ]]; then
    CPU_MAX_VALUE="max 100000"
else
    PERCENT="${CPU%\%}"
    QUOTA=$(( PERCENT * 100000 / 100 ))
    CPU_MAX_VALUE="$QUOTA 100000"
fi

echo "CPU_MAX_VALUE=$CPU_MAX_VALUE"

CGROUP_NAME="mycontainer-$$"
CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"

# 첫 자원(세션 cgroup)을 만들기 직전부터 TERM/INT 를 받으면 정리한다. 이 앞(옵션, rootfs 검사)은 되돌릴 자원이 없다
# 이 스크립트를 & 로 띄우면(러너 B안) bash 가 INT 를 무시 상태로 물려받아 아래 INT trap 은 효과가 없다
# TERM trap 과 러너의 cgroup.kill 정리는 이 영향을 받지 않는다
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
sudo mkdir "$CGROUP_PATH"
# cgroup v2 에서는 디렉토리 inode 가 cgroup id 이다. run 모드도 mycontainer_run 이 감시 맵에 등록하므로 모드와 상관없이 구한다 (정리 단계의 맵 삭제 키)
CGROUP_ID=$(stat -c %i "$CGROUP_PATH")
if [[ "$MODE" == "agent" ]]; then
    SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    SESSIONS_ROOT="${MYC_SESSIONS_ROOT:-/var/lib/mycontainer/sessions}"
    SESSION_DIR="$SESSIONS_ROOT/$SESSION_ID"
    sudo mkdir -p "$SESSION_DIR"
    # 시작 표시 파일 경로 (세션 ID 가 시각과 PID 라 세션 폴더가 매번 새로 생기므로, 이전 실행의 표시가 남아 있지 않다고 본다)
    START_MARK="$SESSION_DIR/started"

    # cgroup id → 세션 대응표. 로더가 첫 이벤트를 받을 때 readlink 로 읽는다.
    sudo mkdir -p "$SESSIONS_ROOT/by-cgroup"
    sudo ln -sfn "../$SESSION_ID" "$SESSIONS_ROOT/by-cgroup/$CGROUP_ID"

    # 세션 정보(meta.json). jq 의 결과를 변수에 먼저 받는다 (파이프로 바로 쓰면 pipefail 이 없어서 jq 가 실패해도 tee 가 빈 meta.json 을 만든다)
    # if 조건 안이라 jq 나 쓰기가 실패해도 set -e 로 끝나지 않는다. 경고만 내고 계속 진행한다 (EXIT trap 이 없어서 여기서 끝나면 cgroup 과 링크가 남는다)
    # 제한값(memory, cpu, pids)은 "max" 같은 문자열이라 --arg 로 넘긴다
    if new_meta="$(jq -n --arg sid "$SESSION_ID" --argjson cid "$CGROUP_ID" \
            --arg start "$(date -Is)" --arg cmd "${CMD[*]}" \
            --argjson sv "$META_SCHEMA_VERSION" --arg rootfs "$ROOTFS_PATH" --arg cgpath "$CGROUP_PATH" \
            --arg mem "$MEMORY" --arg cpu "$CPU" --arg pids "$PIDS" \
            '{session_id:$sid, cgroup_id:$cid, started_at:$start, command:$cmd, schema_version:$sv, rootfs:$rootfs, cgroup_path:$cgpath, limits:{memory:$mem, cpu:$cpu, pids:$pids}}')" \
        && [[ -n "$new_meta" ]]; then
        # 0600: 파일을 먼저 만들고 600 으로 맞춘 뒤 내용을 쓴다 (tee 는 기존 파일의 권한을 유지한다)
        if ! { sudo touch "$SESSION_DIR/meta.json" \
                && sudo chmod 600 "$SESSION_DIR/meta.json" \
                && sudo tee "$SESSION_DIR/meta.json" > /dev/null <<< "$new_meta"; }; then
            echo "[!] meta.json 생성 실패 (쓰기): $SESSION_DIR/meta.json (계속 진행)" >&2
        fi
    else
        echo "[!] meta.json 생성 실패 (jq): $SESSION_DIR (meta.json 없이 계속 진행)" >&2
    fi
    echo "[*] 세션 시작: $SESSION_ID (cgroup_id=$CGROUP_ID)"
fi

echo "$MEMORY" | sudo tee "$CGROUP_PATH/memory.max" > /dev/null
echo "$CPU_MAX_VALUE" | sudo tee "$CGROUP_PATH/cpu.max" > /dev/null
echo "$PIDS" | sudo tee "$CGROUP_PATH/pids.max" > /dev/null

NETNS_NAME="mycontainer-$$"
VETH_HOST="v-$$"
VETH_PEER="v-$$-p"

sudo ip netns add "$NETNS_NAME"
sudo ip link add "$VETH_HOST" type veth peer name "$VETH_PEER"
sudo ip link set "$VETH_PEER" netns "$NETNS_NAME"

VETH_PEER_IP="10.0.0.11/24"
BRIDGE_IP="10.0.0.1/24"
BRIDGE_GATEWAY_IP="10.0.0.1"

sudo ip netns exec "$NETNS_NAME" ip addr add "$VETH_PEER_IP" dev "$VETH_PEER"
sudo ip netns exec "$NETNS_NAME" ip link set "$VETH_PEER" up
sudo ip netns exec "$NETNS_NAME" ip link set lo up

sudo ip link show br0 2> /dev/null || {
    sudo ip link add br0 type bridge
    sudo ip link set br0 up
    sudo ip addr add "$BRIDGE_IP" dev br0
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o enp0s1 -j MASQUERADE
    sudo iptables -A FORWARD -i br0 -o enp0s1 -j ACCEPT
    sudo iptables -A FORWARD -i enp0s1 -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
}

sudo ip link set "$VETH_HOST" master br0
sudo ip link set "$VETH_HOST" up

sudo ip netns exec "$NETNS_NAME" ip route add default via "$BRIDGE_GATEWAY_IP"

# 상위 디렉토리 미리 생성하기.
sudo mkdir -p "$(dirname "$CONTAINER_DIR")"

# --- 여기만 기존 pivot_root_container에서 mycontainer_run으로 교체 ---
# 인자 순서: <lowerdir> <컨테이너 작업디렉토리> <cgroup 경로> <netns 이름> <실행할 프로그램...>
set +e
# 여기부터 감시 맵에 이 세션 항목이 있을 수 있다 (정리 단계가 맵 삭제를 한다)
MC_STARTED=1
# MYC_START_MARK: clone 이 성공하면 mycontainer_run 이 이 경로에 시작 표시 파일을 만든다 (run 모드에서는 빈 값이라 만들지 않는다)
MYC_START_MARK="$START_MARK" ./mycontainer_run "$ROOTFS_PATH" "$CONTAINER_DIR" "$CGROUP_PATH" "$NETNS_NAME" "${CMD[@]}"
RC=$?
set -e

# 정리 단계 (감시 맵 항목 삭제 -> cgroup rmdir 재시도 -> netns 삭제 -> meta.json 갱신). 함수 안의 exit "$RC" 로 끝난다
cleanup_session
