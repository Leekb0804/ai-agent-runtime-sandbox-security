#!/bin/bash
#
# tools/leak_check.sh  -  세션 반복 실행의 자원 누수 점검기
#
# ===== 이 파일의 역할 =====
# 러너(run_scenarios.sh --repeat N)가 반복 중간중간 호스트 자원을 세어 스냅샷으로 남기고(snapshot),
# 끝나면 첫 스냅샷과 마지막 스냅샷을 비교해 누수를 판정한다(compare). 중간 점검 3번 "100회 반복 누수 0" 용이다.
#
#   tools/leak_check.sh snapshot <저장 폴더> <라벨> <라운드 수> <세션 수>
#   tools/leak_check.sh compare [--fd-extra N] [--rss-limit-kb N] <저장 폴더>
#   sudo tools/leak_check.sh selftest      # 맵 항목 개수 읽기가 실제 개수를 따라가는지 (VM, sudo 필요)
#
# ===== 판정 기준 (compare) =====
#   엄격 0 증가   : cgroup 디렉터리, netns, veth, 마운트, 프로세스, 좀비, 감시 맵 항목, iptables 줄 수, 러너 작업 폴더, _unattributed
#   정확히 선형   : 컨테이너 폴더, 세션 폴더, by-cgroup 링크 (증가량 = 실행한 세션 수)
#   kill 과 같음  : state 파일 (증가량 = kill 세션 수 증가량. kill 경로에서만 남는다. kill 세션 = 세션 루트의 meta.json exit_code 137)
#   포화 후 정지  : 로더 FD (후반부 스냅샷 사이 증가 0, 그리고 전체가 고정분 + FD_EXTRA 이하)
#   한계 이내     : 로더 RSS (후반부 첫 스냅샷과 마지막 스냅샷의 차이가 RSS_LIMIT_KB 이하)
#   기록만        : write_tags 항목 수, 컨테이너 폴더 디스크 사용량
#   후반부 = 라운드가 마지막 라운드의 절반 이상이고 로더가 떠 있던 스냅샷들
#
# ===== 종료 코드 =====
#   0 합격   1 누수 또는 기준 위반   2 사용 오류, 스냅샷 부족, 값이 비었거나 읽지 못함 (합격으로 치지 않는다)
#
# ===== 경로 (코드에서 확인한 값. 시험용으로 환경변수로 바꿀 수 있다) =====
#   MYC_LEAK_CGROUP_ROOT      /sys/fs/cgroup                     (run_container.sh 의 CGROUP_PATH)
#   MYC_LEAK_CONTAINERS_ROOT  /var/lib/mycontainer/containers    (run_container.sh 의 CONTAINER_DIR 의 부모)
#   MYC_LEAK_SESS_ROOT        /var/lib/mycontainer/sessions      (run_container.sh 의 SESSIONS_ROOT. 러너는 자기 작업 폴더의 sessions 를 넘긴다)
#   MYC_LEAK_PIN              /sys/fs/bpf/session_cgroups        (mycontainer_run.c 의 SESSION_CGROUPS_PIN)
#   MYC_LEAK_TMP              /tmp                               (러너 작업 폴더 myc_scen.* 의 부모)
#   MYC_LEAK_SELF_WORK        (비어 있음)                         지금 러너의 작업 폴더. 작업 폴더 개수에서 뺀다
#   MYC_LEAK_LOADER_PID       정해져 있으면(빈 값 포함) 그 값을 쓰고, 없으면 pgrep -x myc_loader
#   MYC_LEAK_BPFTOOL, MYC_LEAK_IPTABLES, MYC_LEAK_IP, MYC_LEAK_MOUNTINFO, MYC_LEAK_PROC : 도구와 읽을 곳
#   MYC_LEAK_FD_EXTRA         132 (세션 칸 64 x 2 + 여유 4)       MYC_LEAK_RSS_LIMIT_KB  1024
#   MYC_LEAK_STABLE_TRIES     20 (0.5초 간격, 최대 10초)

# 값이 정해지지 않은 변수를 쓰면 멈춘다 (오타 방지)
set -u

# 읽을 경로와 도구. 평소에는 기본값, 시험에서만 바꾼다
CG_ROOT="${MYC_LEAK_CGROUP_ROOT:-/sys/fs/cgroup}"
# 컨테이너 폴더(upper/work/merged)들의 부모
CONT_ROOT="${MYC_LEAK_CONTAINERS_ROOT:-/var/lib/mycontainer/containers}"
# 세션 폴더와 by-cgroup 링크가 있는 세션 루트
SESS_ROOT="${MYC_LEAK_SESS_ROOT:-/var/lib/mycontainer/sessions}"
# 로더가 pin 하는 감시 맵
PIN="${MYC_LEAK_PIN:-/sys/fs/bpf/session_cgroups}"
# 러너 작업 폴더의 부모와, 세지 않을 지금 러너의 작업 폴더
TMP_BASE="${MYC_LEAK_TMP:-/tmp}"
# 지금 러너의 작업 폴더 (비어 있으면 빼지 않는다)
SELF_WORK="${MYC_LEAK_SELF_WORK:-}"
# 도구들
BPFTOOL="${MYC_LEAK_BPFTOOL:-bpftool}"
# iptables 명령 (root 가 필요하다)
IPTABLES="${MYC_LEAK_IPTABLES:-iptables}"
# ip 명령
IPCMD="${MYC_LEAK_IP:-ip}"
# 호스트(이 프로세스) 마운트 목록
MOUNTINFO="${MYC_LEAK_MOUNTINFO:-/proc/self/mountinfo}"
# 프로세스 목록을 읽을 곳
PROC="${MYC_LEAK_PROC:-/proc}"
# 안정화 대기 횟수 (0.5초 간격)
STABLE_TRIES="${MYC_LEAK_STABLE_TRIES:-20}"
# 판정 기준값 (compare 의 옵션이 이 값을 덮어쓴다)
FD_EXTRA="${MYC_LEAK_FD_EXTRA:-132}"
# 후반부 RSS 증가 한계 (kB)
RSS_LIMIT_KB="${MYC_LEAK_RSS_LIMIT_KB:-1024}"
# 로더의 세션 칸 수 (src/loader/session_log.c 의 MAX_SESSIONS). 칸이 다 차기 전에는 세션마다 로그 FD 가 늘어나는 것이 정상이다
SESSION_SLOTS=64

# 사용법을 stderr 로 내고 2 로 끝낸다
usage() {
    # 머리 주석의 사용법 줄들을 보여 준다
    sed -n '9,11p' "$0" | sed 's/^# \{0,1\}//' >&2
    # 사용 오류
    exit 2
}

# ---------------------------------------------------------------------------------------------
# 세는 함수들. 읽지 못하면 빈 문자열을 출력한다 (compare 가 빈 값을 판정 불가로 본다)
# ---------------------------------------------------------------------------------------------

# 세션 cgroup 디렉터리 개수 (/sys/fs/cgroup/mycontainer-*)
count_cgroups() {
    # 루트를 읽을 수 없으면 빈 값
    [[ -d "$CG_ROOT" ]] || return 0
    # 맞는 것이 없으면 빈 배열이 되게 한다 (이 함수 안에서만)
    local a=() d
    # 이름이 mycontainer- 로 시작하는 디렉터리를 모은다
    for d in "$CG_ROOT"/mycontainer-*/; do [[ -d "$d" ]] && a+=("$d"); done
    # 개수
    echo "${#a[@]}"
}

# 호스트 netns 중 이름이 mycontainer- 로 시작하는 것 (container1, container2 같은 다른 실험 것은 세지 않는다)
count_netns() {
    # ip 출력. 실패하면 빈 값
    local out
    out="$("$IPCMD" netns list 2>/dev/null)" || return 0
    # 각 줄의 첫 단어가 이름이다. 맞는 줄 수를 센다 (없으면 0)
    awk '$1 ~ /^mycontainer-/ {n++} END {print n+0}' <<<"$out"
}

# 호스트 쪽 veth (이름이 v- 로 시작하는 링크)
count_veth() {
    # ip -o 는 링크 하나를 한 줄로 낸다. 실패하면 빈 값
    local out
    out="$("$IPCMD" -o link show 2>/dev/null)" || return 0
    # 둘째 칸이 "v-1234@if5" 꼴이다. 맞는 줄 수를 센다
    awk -F': ' '$2 ~ /^v-/ {n++} END {print n+0}' <<<"$out"
}

# 호스트 마운트 중 mycontainer 나 overlay 가 들어간 줄 (netns 의 nsfs 마운트도 이름으로 걸린다)
count_mounts() {
    # 읽을 수 없으면 빈 값
    [[ -r "$MOUNTINFO" ]] || return 0
    # 맞는 줄 수 (없으면 0)
    awk '/mycontainer|overlay/ {n++} END {print n+0}' "$MOUNTINFO"
}

# 감시 맵 session_cgroups 의 항목 수 (bpftool -j 의 배열 길이)
count_map() {
    # 맵 전체를 JSON 으로 받는다. 실패하면 빈 값
    local out
    out="$("$BPFTOOL" -j map dump pinned "$PIN" 2>/dev/null)" || return 0
    # 배열이 아니면 jq 가 실패해 빈 값이 된다
    jq -e 'if type == "array" then length else error("배열 아님") end' <<<"$out" 2>/dev/null
}

# write_tags 맵 항목 수 (기록용). 로더가 안 떠 있으면 맵이 없어 빈 값이다
count_tags() {
    # 이름이 write_tags 인 맵의 id 를 찾는다 (여러 개면 마지막 것)
    local id out
    id="$("$BPFTOOL" -j map show 2>/dev/null | jq -r '[.[] | select(.name == "write_tags") | .id] | last // empty' 2>/dev/null)"
    # 못 찾으면 빈 값
    [[ -n "$id" ]] || return 0
    # 그 맵을 덤프해 길이를 센다
    out="$("$BPFTOOL" -j map dump id "$id" 2>/dev/null)" || return 0
    # 배열 길이
    jq -e 'if type == "array" then length else error("배열 아님") end' <<<"$out" 2>/dev/null
}

# 세션 관련 프로세스 수와 그중 좀비 수를 "개수 좀비수" 한 줄로 낸다.
# 대상: 이름이 mycontainer 나 run_container 로 시작하는 것, 그리고 cgroup 이 /mycontainer- 아래인 것(컨테이너 안 sh 와 자식, mycontainer_run)
count_procs() {
    # 개수, 좀비 수, 반복 변수들
    local n=0 z=0 p comm cg st
    # /proc 를 읽을 수 없으면 빈 값
    [[ -d "$PROC" ]] || return 0
    # 숫자 이름 폴더가 프로세스다
    for p in "$PROC"/[0-9]*; do
        # 그 사이에 끝난 프로세스는 건너뛴다
        comm="$(cat "$p/comm" 2>/dev/null)" || continue
        # cgroup 경로 (읽지 못하면 빈 값)
        cg="$(cat "$p/cgroup" 2>/dev/null)"
        # 대상이 아니면 건너뛴다
        [[ "$comm" == mycontainer* || "$comm" == run_container* || "$cg" == *"/mycontainer-"* ]] || continue
        # 하나 센다
        n=$((n + 1))
        # stat 의 상태 글자: 이름 괄호 뒤의 첫 글자이다 (이름에 공백이 있어도 되도록 마지막 ") " 뒤를 본다)
        st="$(cat "$p/stat" 2>/dev/null)"
        # ") " 뒤의 첫 글자가 Z 이면 좀비
        st="${st##*) }"
        # 좀비를 센다
        [[ "${st:0:1}" == Z ]] && z=$((z + 1))
    done
    # 두 값을 한 줄로
    echo "$n $z"
}

# iptables 규칙 줄 수. 인자: 테이블 이름 (filter 또는 nat)
count_ipt() {
    # 출력. 실패하면(권한 등) 빈 값
    local out
    out="$("$IPTABLES" -t "$1" -S 2>/dev/null)" || return 0
    # 줄 수
    wc -l <<<"$out" | tr -d ' '
}

# 러너 작업 폴더(myc_scen.*) 개수. 지금 러너의 작업 폴더는 뺀다
count_work() {
    # 부모가 없으면 빈 값
    [[ -d "$TMP_BASE" ]] || return 0
    # 개수와 반복 변수
    local n=0 d
    # 이름이 myc_scen. 으로 시작하는 폴더
    for d in "$TMP_BASE"/myc_scen.*/; do
        # 맞는 것이 없으면 건너뛴다
        [[ -d "$d" ]] || continue
        # 지금 러너의 폴더는 세지 않는다
        [[ -n "$SELF_WORK" && "${d%/}" == "$SELF_WORK" ]] && continue
        # 센다
        n=$((n + 1))
    done
    # 개수
    echo "$n"
}

# _unattributed 에 기록된 줄 수 (폴더가 없으면 0. 있으면 events, verdicts 의 줄 수 합)
count_unattr() {
    # 세션 루트가 없으면 빈 값
    [[ -d "$SESS_ROOT" ]] || return 0
    # 폴더가 없으면 기록이 없는 것이다
    [[ -d "$SESS_ROOT/_unattributed" ]] || { echo 0; return 0; }
    # 폴더 안 파일들의 줄 수 합 (파일이 없으면 0)
    cat "$SESS_ROOT/_unattributed"/* 2>/dev/null | wc -l | tr -d ' '
}

# 컨테이너 폴더 개수 (루트가 아직 없으면 0. 첫 컨테이너 때 run_container.sh 가 만든다)
count_containers() {
    # 루트가 없으면 0
    [[ -d "$CONT_ROOT" ]] || { echo 0; return 0; }
    # 개수와 반복 변수
    local a=() d
    # mycontainer-* 폴더를 모은다
    for d in "$CONT_ROOT"/mycontainer-*/; do [[ -d "$d" ]] && a+=("$d"); done
    # 개수
    echo "${#a[@]}"
}

# 컨테이너 폴더 전체의 디스크 사용량 (바이트, 기록용)
bytes_containers() {
    # 루트가 없으면 0
    [[ -d "$CONT_ROOT" ]] || { echo 0; return 0; }
    # du 출력. 일부라도 읽지 못하면(권한 등) du 가 0 이 아닌 값으로 끝나므로 빈 값으로 둔다
    local out
    out="$(du -sb "$CONT_ROOT" 2>/dev/null)" || return 0
    # 첫 칸이 바이트 수
    awk '{print $1}' <<<"$out"
}

# 남은 state 파일 개수 (컨테이너 폴더 안의 state)
count_state() {
    # 루트가 없으면 0
    [[ -d "$CONT_ROOT" ]] || { echo 0; return 0; }
    # 개수와 반복 변수
    local n=0 f
    # 컨테이너 폴더마다 state 가 있는지
    for f in "$CONT_ROOT"/mycontainer-*/state; do [[ -e "$f" ]] && n=$((n + 1)); done
    # 개수
    echo "$n"
}

# by-cgroup 링크 개수 (폴더가 없으면 0)
count_links() {
    # 세션 루트가 없으면 빈 값
    [[ -d "$SESS_ROOT" ]] || return 0
    # by-cgroup 폴더가 없으면 0
    [[ -d "$SESS_ROOT/by-cgroup" ]] || { echo 0; return 0; }
    # 개수와 반복 변수
    local n=0 f
    # 링크만 센다
    for f in "$SESS_ROOT/by-cgroup"/*; do [[ -L "$f" ]] && n=$((n + 1)); done
    # 개수
    echo "$n"
}

# kill 로 끝난 세션 수: 세션 루트의 meta.json 중 exit_code 가 137 인 것.
# run_container.sh 는 mycontainer_run 의 종료 코드를 meta.json 에 쓰고, cgroup.kill 로 mycontainer_run 이 SIGKILL 을 받으면 137 이다.
# meta.json 을 읽지 못하거나 JSON 이 깨졌으면 빈 값 (exit_code 가 없는 것은 137 이 아니므로 세지 않는다)
count_kills() {
    # 세션 루트가 없으면 빈 값
    [[ -d "$SESS_ROOT" ]] || return 0
    # 개수와 반복 변수, jq 결과
    local n=0 f rc
    # 세션 폴더마다 meta.json 을 본다
    for f in "$SESS_ROOT"/*/meta.json; do
        # 맞는 것이 없으면 건너뛴다
        [[ -e "$f" ]] || continue
        # exit_code 를 읽는다. 키가 없으면 빈 문자열. 읽기나 JSON 해석이 실패하면 전체를 빈 값으로 한다
        rc="$(jq -r '.exit_code // empty' "$f" 2>/dev/null)" || return 0
        # 137 이면 센다
        [[ "$rc" == 137 ]] && n=$((n + 1))
    done
    # 개수
    echo "$n"
}

# 세션 폴더 개수 (by-cgroup 과 _unattributed 는 빼고 디렉터리만)
count_sessions() {
    # 세션 루트가 없으면 빈 값
    [[ -d "$SESS_ROOT" ]] || return 0
    # 개수와 반복 변수
    local n=0 d b
    # 하위 디렉터리를 본다
    for d in "$SESS_ROOT"/*/; do
        # 맞는 것이 없으면 건너뛴다
        [[ -d "$d" ]] || continue
        # 이름만
        b="$(basename "$d")"
        # 세션 폴더가 아닌 것은 뺀다
        [[ "$b" == by-cgroup || "$b" == _unattributed ]] && continue
        # 센다
        n=$((n + 1))
    done
    # 개수
    echo "$n"
}

# ---------------------------------------------------------------------------------------------
# snapshot
# ---------------------------------------------------------------------------------------------
cmd_snapshot() {
    # 인자 네 개가 필요하다
    [[ $# -eq 4 ]] || usage
    # 저장 폴더, 라벨, 라운드 수, 세션 수
    local dir="$1" label="$2" round="$3" sessions="$4"
    # 라운드와 세션은 0 이상의 정수여야 한다
    [[ "$round" =~ ^[0-9]+$ && "$sessions" =~ ^[0-9]+$ ]] || { echo "[leak_check] 라운드와 세션 수는 0 이상의 정수여야 한다: '$round' '$sessions'" >&2; exit 2; }
    # 라벨은 파일 이름에 쓰므로 영문, 숫자, _ - 만 받는다
    [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "[leak_check] 라벨은 영문, 숫자, _ - 만 쓸 수 있다: '$label'" >&2; exit 2; }
    # 저장 폴더가 없으면 사용 오류
    [[ -d "$dir" ]] || { echo "[leak_check] 저장 폴더가 없다: $dir" >&2; exit 2; }

    # 안정화 대기: cgroup 디렉터리 수와 프로세스 수가 연속 두 번 같아질 때까지 0.5초 간격으로 기다린다
    local i prev="" cur stable=0
    for ((i = 0; i < STABLE_TRIES; i++)); do
        # 지금 값 (두 값을 한 문자열로)
        cur="$(count_cgroups)|$(count_procs)"
        # 직전 값과 같으면 안정된 것이다
        if [[ -n "$prev" && "$cur" == "$prev" ]]; then stable=1; break; fi
        # 다음 비교를 위해 기억한다
        prev="$cur"
        # 잠깐 쉰다
        sleep 0.5
    done

    # 로더 pid: 러너가 넘긴 값이 있으면(빈 값 포함) 그것, 없으면 이름으로 찾는다 (정확히 하나일 때만)
    local lpid=""
    if [[ -v MYC_LEAK_LOADER_PID ]]; then
        # 러너가 준 값 (빈 값이면 로더가 안 떠 있는 것)
        lpid="$MYC_LEAK_LOADER_PID"
    else
        # 이름이 정확히 myc_loader 인 프로세스
        lpid="$(pgrep -x myc_loader 2>/dev/null)"
        # 여러 개면 어느 것인지 모르므로 비운다
        [[ "$lpid" =~ ^[0-9]+$ ]] || lpid=""
    fi
    # 로더가 살아 있는지 (pid 가 있고 /proc 에 있으면)
    local lrun=0 lfd="" lrss=""
    if [[ -n "$lpid" && -d "$PROC/$lpid" ]]; then
        # 떠 있다
        lrun=1
        # 열린 FD 개수. 읽지 못하면(권한) 빈 값
        lfd="$(ls -1 "$PROC/$lpid/fd" 2>/dev/null | wc -l | tr -d ' ')"
        # ls 가 실패했으면 0 이 아니라 빈 값으로 둔다
        ls "$PROC/$lpid/fd" >/dev/null 2>&1 || lfd=""
        # VmRSS (kB)
        lrss="$(awk '/^VmRSS:/ {print $2}' "$PROC/$lpid/status" 2>/dev/null)"
    fi

    # 프로세스 수와 좀비 수
    local pz procs="" zombies=""
    pz="$(count_procs)"
    # 둘로 나눈다 (읽지 못했으면 둘 다 빈 값)
    if [[ -n "$pz" ]]; then procs="${pz% *}"; zombies="${pz#* }"; fi

    # 순번: 이미 있는 스냅샷 수 + 1 (파일 이름 순서가 찍은 순서가 되게 세 자리로)
    local n=1 f
    for f in "$dir"/*.snap; do [[ -e "$f" ]] && n=$((n + 1)); done
    # 파일 이름
    local out
    out="$dir/$(printf '%03d' "$n")_$label.snap"
    # key=value 로 쓴다. 임시 파일에 쓰고 옮겨서 반쯤 쓴 파일이 남지 않게 한다
    {
        echo "label=$label"
        echo "seq=$n"
        echo "round=$round"
        echo "sessions=$sessions"
        echo "time=$(date -Is)"
        echo "stable=$stable"
        echo "loader_running=$lrun"
        echo "loader_pid=$lpid"
        echo "loader_fd=$lfd"
        echo "loader_rss_kb=$lrss"
        echo "cgroup_dirs=$(count_cgroups)"
        echo "netns=$(count_netns)"
        echo "veth=$(count_veth)"
        echo "mounts=$(count_mounts)"
        echo "procs=$procs"
        echo "zombies=$zombies"
        echo "map_entries=$(count_map)"
        echo "ipt_filter=$(count_ipt filter)"
        echo "ipt_nat=$(count_ipt nat)"
        echo "work_dirs=$(count_work)"
        echo "unattributed=$(count_unattr)"
        echo "container_dirs=$(count_containers)"
        echo "container_bytes=$(bytes_containers)"
        echo "state_files=$(count_state)"
        echo "bycgroup_links=$(count_links)"
        echo "session_dirs=$(count_sessions)"
        echo "kill_sessions=$(count_kills)"
        echo "write_tags=$(count_tags)"
    } >"$out.tmp" && mv "$out.tmp" "$out"
    # 어디에 썼는지 알린다
    echo "[leak_check] 스냅샷: $out (안정=$stable)"
}

# ---------------------------------------------------------------------------------------------
# compare
# ---------------------------------------------------------------------------------------------
# 스냅샷 값을 담는 표. 키는 "번호:항목" (번호는 0 부터, 파일 이름 순)
declare -A V
# 판정 결과: 실패 수와 판정 불가 수
NFAIL=0
# 판정 불가 수
NNA=0

# 표의 한 줄을 낸다. 인자: 판정(PASS/FAIL/N/A/INFO), 항목, 기준, 처음, 마지막, 차이, 덧붙일 말
row() {
    # 고정 폭으로 맞춘다. 첫 칸이 판정이라 시험이 ^FAIL 로 찾는다
    printf '%-4s %-16s %-12s %10s %10s %8s  %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7-}"
    # 집계
    [[ "$1" == FAIL ]] && NFAIL=$((NFAIL + 1))
    # 판정 불가 집계
    [[ "$1" == N/A ]] && NNA=$((NNA + 1))
    # 함수의 종료 코드를 0 으로 (위 [[ ]] 가 거짓이어도 실패로 보이지 않게)
    return 0
}

# 값이 0 이상의 정수인가
is_int() { [[ "${1-}" =~ ^[0-9]+$ ]]; }

cmd_compare() {
    # 옵션을 읽는다
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # FD 상한 여유 (고정분 위로 허용하는 개수)
            --fd-extra) [[ $# -ge 2 ]] || usage; FD_EXTRA="$2"; shift 2 ;;
            # 후반부 RSS 증가 한계 (kB)
            --rss-limit-kb) [[ $# -ge 2 ]] || usage; RSS_LIMIT_KB="$2"; shift 2 ;;
            # 나머지는 위치 인자
            -*) usage ;;
            *) break ;;
        esac
    done
    # 저장 폴더 하나가 남아야 한다
    [[ $# -eq 1 ]] || usage
    # 기준값도 정수여야 한다
    is_int "$FD_EXTRA" && is_int "$RSS_LIMIT_KB" || { echo "[leak_check] 기준값은 0 이상의 정수여야 한다: fd-extra='$FD_EXTRA' rss-limit-kb='$RSS_LIMIT_KB'" >&2; exit 2; }
    # 저장 폴더
    local dir="$1" f i=0 line k v
    [[ -d "$dir" ]] || { echo "[leak_check] 저장 폴더가 없다: $dir" >&2; exit 2; }

    # 스냅샷 파일을 이름 순서로 읽어 표에 담는다
    local files=()
    for f in "$dir"/*.snap; do [[ -f "$f" ]] && files+=("$f"); done
    # 둘 이상이어야 비교할 수 있다
    if ((${#files[@]} < 2)); then echo "[leak_check] 스냅샷이 둘 이상 필요하다 (지금 ${#files[@]}개): $dir" >&2; exit 2; fi
    # 파일마다 key=value 줄을 읽는다
    for f in "${files[@]}"; do
        # 줄 단위로 읽는다 (= 앞이 키, 뒤가 값)
        while IFS= read -r line; do
            # = 가 없는 줄은 무시한다
            [[ "$line" == *=* ]] || continue
            # 키와 값
            k="${line%%=*}"; v="${line#*=}"
            # 표에 넣는다
            V["$i:$k"]="$v"
        done <"$f"
        # 다음 번호
        i=$((i + 1))
    done
    # 스냅샷 수, 마지막 번호
    local ns=$i last=$((i - 1))

    # 머리 줄
    echo "[leak_check] 스냅샷 $ns개: 처음 ${V[0:label]-?} (라운드 ${V[0:round]-?}, 세션 ${V[0:sessions]-?}), 마지막 ${V[$last:label]-?} (라운드 ${V[$last:round]-?}, 세션 ${V[$last:sessions]-?})"
    printf '%-4s %-16s %-12s %10s %10s %8s  %s\n' 판정 항목 기준 처음 마지막 차이 비고

    # 공통 값 검사: 라운드, 세션, 안정 여부는 모든 스냅샷에 있어야 한다
    local s ok=1
    for ((s = 0; s < ns; s++)); do
        # 정수가 아니면 표 전체를 믿을 수 없다
        if ! is_int "${V[$s:round]-}" || ! is_int "${V[$s:sessions]-}"; then ok=0; fi
        # 안정되지 않은 스냅샷이 있으면 판정 불가로 표시한다
        if [[ "${V[$s:stable]-}" != 1 ]]; then row N/A stable 안정 - - - "스냅샷 ${V[$s:label]-?} 이 10초 안에 안정되지 않음 (stable=${V[$s:stable]-빈값})"; fi
    done
    # 라운드나 세션 값이 깨졌으면 더 볼 것이 없다
    if [[ $ok -ne 1 ]]; then echo "[leak_check] 라운드나 세션 값이 비었거나 정수가 아니다" >&2; exit 2; fi
    # 세션 증가량
    local dsess=$(( V[$last:sessions] - V[0:sessions] ))

    # 처음과 마지막 값을 꺼내는 도우미. 둘 다 정수가 아니면 N/A 행을 내고 1 을 돌려준다
    local a b d
    get_ab() {
        # 처음 값과 마지막 값
        a="${V[0:$1]-}"; b="${V[$last:$1]-}"
        # 둘 다 정수여야 한다
        if is_int "$a" && is_int "$b"; then d=$((b - a)); return 0; fi
        # 비었거나 읽지 못했다
        row N/A "$1" "$2" "${a:-빈값}" "${b:-빈값}" - "값이 비었거나 읽지 못함"
        return 1
    }

    # 1) 엄격 0 증가
    for k in cgroup_dirs netns veth mounts procs zombies map_entries ipt_filter ipt_nat work_dirs unattributed; do
        # 값이 없으면 N/A 를 이미 냈다
        get_ab "$k" "0 증가" || continue
        # 맵은 시작 전 항목이 남아 있으면 경고만 한다 (pin 된 맵은 로더를 다시 띄워도 남는다)
        local note=""
        [[ "$k" == map_entries && "$a" -ne 0 ]] && note="경고: 시작 전 항목 $a 개 (차이로만 판정)"
        # 차이가 0 이면 합격
        if [[ $d -eq 0 ]]; then row PASS "$k" "0 증가" "$a" "$b" "$d" "$note"; else row FAIL "$k" "0 증가" "$a" "$b" "$d" "$note"; fi
    done

    # 2) 정확히 선형 (증가량 = 세션 수)
    for k in container_dirs session_dirs bycgroup_links; do
        # 값이 없으면 N/A
        get_ab "$k" "+세션수" || continue
        # 증가량이 세션 증가량과 같아야 한다
        if [[ $d -eq $dsess ]]; then row PASS "$k" "+$dsess" "$a" "$b" "$d"; else row FAIL "$k" "+$dsess" "$a" "$b" "$d" "증가량이 세션 수와 다름"; fi
    done

    # 3) state 파일: 증가량이 kill 세션 수 증가량과 정확히 같아야 한다 (kill 경로에서만 남는다)
    # kill 세션 수부터 읽는다. 비었거나 읽지 못하면 state 도 판정할 수 없다
    if get_ab kill_sessions 기준값; then
        # kill 세션 증가량
        local dkill=$d
        # 기준값 행 (판정 대상은 아니고 값을 보여 준다)
        row INFO kill_sessions 기준값 "$a" "$b" "$d" "meta.json exit_code 137 인 세션"
        # state 증가량이 kill 세션 증가량과 같아야 한다
        if get_ab state_files "+kill수"; then
            if [[ $d -eq $dkill ]]; then row PASS state_files "+$dkill" "$a" "$b" "$d" "kill 세션 수와 같음"; else row FAIL state_files "+$dkill" "$a" "$b" "$d" "증가량이 kill 세션 수와 다름"; fi
        fi
    else
        # kill 세션 수를 모르면 state 도 판정 불가
        row N/A state_files "+kill수" "${V[0:state_files]:-빈값}" "${V[$last:state_files]:-빈값}" - "kill 세션 수를 읽지 못해 판정할 수 없음"
    fi

    # 4), 5) 로더 FD 와 RSS: 로더가 떠 있던 스냅샷만 쓴다. 떠 있던 스냅샷의 FD, RSS 는 비면 안 된다
    local run=() bad=0
    for ((s = 0; s < ns; s++)); do
        # 로더가 안 떠 있던 스냅샷(시작 전)은 건너뛴다
        [[ "${V[$s:loader_running]-}" == 1 ]] || continue
        # 떠 있었는데 값이 비었으면 판정 불가
        if ! is_int "${V[$s:loader_fd]-}" || ! is_int "${V[$s:loader_rss_kb]-}"; then bad=1; fi
        # 목록에 넣는다
        run+=("$s")
    done
    # 값 전부를 보여 준다 (첫 실행은 값을 보는 것이 목적)
    local seq_txt=""
    for s in "${run[@]}"; do seq_txt+="${V[$s:label]}(r${V[$s:round]},s${V[$s:sessions]}):fd=${V[$s:loader_fd]-빈값},rss=${V[$s:loader_rss_kb]-빈값} "; done
    echo "[leak_check] 로더 값: ${seq_txt:-없음}"
    # 후반부: 라운드 x 2 가 마지막 라운드 이상인 스냅샷
    local late=() lr="${V[$last:round]}"
    for s in "${run[@]}"; do (( V[$s:round] * 2 >= lr )) && late+=("$s"); done
    if [[ ${#run[@]} -eq 0 || $bad -eq 1 ]]; then
        # 로더 값을 하나도 못 읽었거나 빈 값이 있다
        row N/A loader_fd 포화후정지 - - - "로더가 떠 있던 스냅샷이 없거나 FD/RSS 가 빈 값"
        row N/A loader_rss_kb 한계이내 - - - "로더가 떠 있던 스냅샷이 없거나 FD/RSS 가 빈 값"
    else
        # 고정분: 로더가 떠 있던 첫 스냅샷의 FD
        local fixed="${V[${run[0]}:loader_fd]}" maxfd=0 grow=0 prev=""
        # 전체 최댓값
        for s in "${run[@]}"; do (( V[$s:loader_fd] > maxfd )) && maxfd="${V[$s:loader_fd]}"; done
        # 상한 검사
        if (( maxfd <= fixed + FD_EXTRA )); then row PASS loader_fd_max "<=$((fixed + FD_EXTRA))" "$fixed" "$maxfd" "$((maxfd - fixed))" "고정분 $fixed + 여유 $FD_EXTRA"; else row FAIL loader_fd_max "<=$((fixed + FD_EXTRA))" "$fixed" "$maxfd" "$((maxfd - fixed))" "상한 초과"; fi
        # 후반부 증가 검사: 후반부 스냅샷이 둘 이상 있어야 한다
        if ((${#late[@]} < 2)); then
            # 판정할 재료가 없다
            row N/A loader_fd_late "후반 0증가" - - - "후반부(라운드 >= $lr/2) 로더 스냅샷이 ${#late[@]}개"
            row N/A loader_rss_kb "<=${RSS_LIMIT_KB}kB" - - - "후반부 로더 스냅샷이 ${#late[@]}개"
        else
            # judged: 센 쌍이 하나라도 있으면 1. psess: 마지막으로 본 앞쪽 스냅샷의 누적 세션 수 (미판정 안내에 쓴다)
            local judged=0 psess=0
            # 이웃한 후반부 스냅샷 사이 증가를 더한다 (감소는 무시)
            for s in "${late[@]}"; do
                # 앞 값이 있으면 그 쌍을 본다
                if [[ -n "$prev" ]]; then
                    # 앞쪽 스냅샷의 누적 세션 수
                    psess="${V[$prev:sessions]}"
                    # 앞쪽이 세션 칸 수 이상일 때만 센다 (그 전에는 칸이 차면서 FD 가 느는 것이 정상이다)
                    if (( psess >= SESSION_SLOTS )); then
                        # 센 쌍이 있다
                        judged=1
                        # 증가분만 더한다
                        if (( V[$s:loader_fd] > V[$prev:loader_fd] )); then grow=$((grow + V[$s:loader_fd] - V[$prev:loader_fd])); fi
                    fi
                fi
                # 다음 비교를 위해 기억한다
                prev="$s"
            done
            # 후반부 처음과 마지막 FD
            local lf="${V[${late[0]}:loader_fd]}" ll="${V[${late[-1]}:loader_fd]}"
            # 센 쌍이 없으면 판정하지 않는다 (INFO 라서 종료 코드에 영향이 없다)
            if [[ $judged -eq 0 ]]; then row INFO loader_fd_late "후반 0증가" "$lf" "$ll" - "미판정 (슬롯 포화 전: 세션 $psess < $SESSION_SLOTS)"
            # 증가가 0 이면 합격
            elif [[ $grow -eq 0 ]]; then row PASS loader_fd_late "후반 0증가" "$lf" "$ll" "+$grow"; else row FAIL loader_fd_late "후반 0증가" "$lf" "$ll" "+$grow" "후반부 스냅샷 사이 증가 합"; fi
            # RSS: 후반부 첫 스냅샷과 마지막 스냅샷의 차이
            local rf="${V[${late[0]}:loader_rss_kb]}" rl="${V[${late[-1]}:loader_rss_kb]}"
            if (( rl - rf <= RSS_LIMIT_KB )); then row PASS loader_rss_kb "<=${RSS_LIMIT_KB}kB" "$rf" "$rl" "$((rl - rf))" "후반부"; else row FAIL loader_rss_kb "<=${RSS_LIMIT_KB}kB" "$rf" "$rl" "$((rl - rf))" "후반부 증가가 한계 초과"; fi
        fi
    fi

    # 6) 기록만: write_tags (로더가 떠 있던 마지막 스냅샷), 디스크 사용량
    local tg="빈값"
    [[ ${#run[@]} -gt 0 ]] && tg="${V[${run[-1]}:write_tags]:-빈값}"
    row INFO write_tags 기록만 - "$tg" - "로더가 떠 있던 마지막 스냅샷"
    if get_ab container_bytes 기록만; then row INFO container_bytes 기록만 "$a" "$b" "$d" "바이트"; fi

    # 종료 코드: 판정 불가가 하나라도 있으면 2, 아니면 실패가 있으면 1, 아니면 0
    if ((NNA > 0)); then echo "[leak_check] 결과: 판정 불가 ${NNA}개, 실패 ${NFAIL}개"; exit 2; fi
    if ((NFAIL > 0)); then echo "[leak_check] 결과: 실패 ${NFAIL}개"; exit 1; fi
    echo "[leak_check] 결과: 합격"
    exit 0
}

# ---------------------------------------------------------------------------------------------
# selftest: count_map 이 실제 항목 수를 따라가는지 VM 에서 확인한다 (root 필요)
# 감시 맵에 없는 cgroup id 하나를 넣었다가 지우고, 그때마다 센 값이 +1, 원래대로 바뀌는지 본다.
# 넣는 id 는 실제 cgroup 이 아닐 큰 수라 감시 대상이 생기지 않는다. 이미 있으면 건드리지 않고 멈춘다.
# ---------------------------------------------------------------------------------------------
cmd_selftest() {
    # root 가 아니면 맵을 바꿀 수 없다
    [[ $EUID -eq 0 ]] || { echo "[leak_check] selftest 는 root 가 필요하다: sudo tools/leak_check.sh selftest" >&2; exit 2; }
    # 시험용 키: 0xfffffffffffffff0 (8바이트 리틀엔디안)
    local key=(0xf0 0xff 0xff 0xff 0xff 0xff 0xff 0xff) n0 n1 n2
    # 시작 값
    n0="$(count_map)"
    is_int "$n0" || { echo "[leak_check] 맵 항목을 셀 수 없다 ($PIN, $BPFTOOL)" >&2; exit 2; }
    # 시험 키가 이미 있으면 남의 항목일 수 있으므로 멈춘다
    if "$BPFTOOL" map lookup pinned "$PIN" key "${key[@]}" >/dev/null 2>&1; then echo "[leak_check] 시험 키가 이미 있다. 건드리지 않고 멈춘다" >&2; exit 2; fi
    # 하나 넣는다 (값은 1바이트 1)
    "$BPFTOOL" map update pinned "$PIN" key "${key[@]}" value 0x01 || { echo "[leak_check] 시험 키를 넣지 못함" >&2; exit 2; }
    # 넣은 뒤 값
    n1="$(count_map)"
    # 지운다
    "$BPFTOOL" map delete pinned "$PIN" key "${key[@]}" || echo "[leak_check] !!! 시험 키를 지우지 못함. 손으로 지울 것: $BPFTOOL map delete pinned $PIN key ${key[*]}" >&2
    # 지운 뒤 값
    n2="$(count_map)"
    # 결과를 보여 준다
    echo "[leak_check] selftest: 시작 $n0, 넣은 뒤 $n1, 지운 뒤 $n2"
    # 넣은 뒤 +1, 지운 뒤 원래 값이어야 한다
    if is_int "$n1" && is_int "$n2" && [[ $n1 -eq $((n0 + 1)) && $n2 -eq $n0 ]]; then echo "[leak_check] selftest 합격"; exit 0; fi
    # 아니면 실패
    echo "[leak_check] selftest 실패: 개수 읽기가 실제 항목 수를 따라가지 않는다"
    exit 1
}

# ---------------------------------------------------------------------------------------------
# 메인: 첫 인자가 하위 명령이다
# ---------------------------------------------------------------------------------------------
# 하위 명령이 없으면 사용 오류
[[ $# -ge 1 ]] || usage
# 하위 명령을 꺼낸다
sub="$1"
shift
# 나눠서 부른다
case "$sub" in
    snapshot) cmd_snapshot "$@" ;;
    compare) cmd_compare "$@" ;;
    selftest) cmd_selftest "$@" ;;
    -h|--help) usage ;;
    *) usage ;;
esac
