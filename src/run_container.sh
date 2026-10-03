#!/bin/bash
set -e

# 소스가 바뀌었거나 바이너리가 없으면 재컴파일
if [[ ! -x ./mycontainer_run || mycontainer_run.c -nt ./mycontainer_run ]]; then
    echo "[*] mycontainer_run.c 컴파일 중..."
    gcc -Wall -o mycontainer_run mycontainer_run.c -lbpf
fi

MEMORY="max"
CPU="max"
PIDS="max"
ROOTFS_PATH="/home/dev/practice/mycontainer/busybox_rootfs"   # 이번엔 lowerdir(이미지 레이어)로 사용됨
CONTAINER_DIR="/var/lib/mycontainer/containers/mycontainer-$$"  # upper/work/merged를 담을 디렉토리
CMD=()
MODE="run"
SESSION_ID=""
SESSION_DIR=""


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
if [[ "$MODE" == "agent" ]]; then
    SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    SESSIONS_ROOT="/var/lib/mycontainer/sessions"
    SESSION_DIR="$SESSIONS_ROOT/$SESSION_ID"
    sudo mkdir -p "$SESSION_DIR"

    CGROUP_ID=$(stat -c %i "$CGROUP_PATH")
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

sudo rmdir "$CGROUP_PATH" || echo "[!] cgroup 정리 실패: $CGROUP_PATH (계속 진행)"
sudo ip netns delete "$NETNS_NAME" || echo "[!] netns 정리 실패: $NETNS_NAME (계속 진행)"

if [[ "$MODE" == "agent" ]]; then
    jq --arg end "$(date -Is)" --argjson rc "$RC" \
       '. + {ended_at:$end, exit_code:$rc}' "$SESSION_DIR/meta.json" \
      | sudo tee "$SESSION_DIR/meta.json.tmp" > /dev/null
    sudo mv "$SESSION_DIR/meta.json.tmp" "$SESSION_DIR/meta.json"
fi

exit "$RC"
