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
if [[ "$MODE" == "agent" ]]; then
    SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    SESSIONS_ROOT="${MYC_SESSIONS_ROOT:-/var/lib/mycontainer/sessions}"
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
