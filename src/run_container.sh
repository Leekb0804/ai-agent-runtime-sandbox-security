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
CGROUP_ID=""
# 감시 맵의 pin 경로. mycontainer_run.c 의 SESSION_CGROUPS_PIN 과 같은 값이어야 한다 (mycontainer_run 이 이 맵에 세션 cgroup 을 등록한다)
SESSION_CGROUPS_PIN="/sys/fs/bpf/session_cgroups"

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

# 세션 정리 단계. mycontainer_run 이 돌아온 뒤 정상 경로가 부르고, 마지막에 mycontainer_run 의 종료 코드(RC)로 끝낸다.
# 순서: 감시 맵 항목 삭제 -> cgroup rmdir 재시도 -> netns 삭제 -> (agent 모드) meta.json 갱신 -> exit "$RC"
# 맵 삭제는 반드시 rmdir 전에 한다. rmdir 뒤에는 cgroup id 가 다른 세션에 재사용될 수 있어 그 id 로 지우면 남의 감시가 풀린다.
cleanup_session() {
    unwatch_session_cgroup

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
    sudo ip netns delete "$NETNS_NAME" || echo "[!] netns 정리 실패: $NETNS_NAME (계속 진행)"

    if [[ "$MODE" == "agent" ]]; then
        jq --arg end "$(date -Is)" --argjson rc "$RC" \
           '. + {ended_at:$end, exit_code:$rc}' "$SESSION_DIR/meta.json" \
          | sudo tee "$SESSION_DIR/meta.json.tmp" > /dev/null
        sudo mv "$SESSION_DIR/meta.json.tmp" "$SESSION_DIR/meta.json"
    fi

    exit "$RC"
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

sudo mkdir "$CGROUP_PATH"
# cgroup v2 에서는 디렉토리 inode 가 cgroup id 이다. run 모드도 mycontainer_run 이 감시 맵에 등록하므로 모드와 상관없이 구한다 (정리 단계의 맵 삭제 키)
CGROUP_ID=$(stat -c %i "$CGROUP_PATH")
if [[ "$MODE" == "agent" ]]; then
    SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    SESSIONS_ROOT="${MYC_SESSIONS_ROOT:-/var/lib/mycontainer/sessions}"
    SESSION_DIR="$SESSIONS_ROOT/$SESSION_ID"
    sudo mkdir -p "$SESSION_DIR"

    # cgroup id → 세션 대응표. 로더가 첫 이벤트를 받을 때 readlink 로 읽는다.
    sudo mkdir -p "$SESSIONS_ROOT/by-cgroup"
    sudo ln -sfn "../$SESSION_ID" "$SESSIONS_ROOT/by-cgroup/$CGROUP_ID"

    jq -n --arg sid "$SESSION_ID" --argjson cid "$CGROUP_ID" \
            --arg start "$(date -Is)" --arg cmd "${CMD[*]}" \
            '{session_id:$sid, cgroup_id:$cid, started_at:$start, command:$cmd}' \
        | sudo tee "$SESSION_DIR/meta.json" > /dev/null
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
./mycontainer_run "$ROOTFS_PATH" "$CONTAINER_DIR" "$CGROUP_PATH" "$NETNS_NAME" "${CMD[@]}"
RC=$?
set -e

# 정리 단계 (감시 맵 항목 삭제 -> cgroup rmdir 재시도 -> netns 삭제 -> meta.json 갱신). 함수 안의 exit "$RC" 로 끝난다
cleanup_session
