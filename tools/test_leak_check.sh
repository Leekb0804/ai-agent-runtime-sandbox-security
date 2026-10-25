#!/bin/bash
#
# tools/test_leak_check.sh  -  누수 점검기(tools/leak_check.sh)의 compare 판정 시험
#
# sudo 없이 돈다. 가짜 스냅샷 폴더를 만들어 compare 가
#   - 정상 값이면 합격(0)
#   - 항목 하나만 어긋나게 바꾸면 정확히 그 항목만 FAIL(1)
#   - 값이 비거나 스냅샷이 부족하면 판정 불가(2)
# 를 내는지 본다. snapshot 과 selftest 는 root 와 실제 자원이 필요해서 VM 에서 확인한다.
#
# 사용법: tools/test_leak_check.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u
# 이 파일이 있는 폴더
HERE="$(cd "$(dirname "$0")" && pwd)"
# 시험 대상
LC="$HERE/leak_check.sh"
# 시험용 임시 폴더 (끝나면 지운다)
T="$(mktemp -d)"
# 끝날 때 임시 폴더를 지운다
trap 'rm -rf "$T"' EXIT
# 실패 수
failures=0
# compare 출력을 모을 파일
OUT="$T/out"

# 스냅샷 파일 하나를 쓴다. 인자: 폴더, 순번, 라벨, 라운드, 세션, 로더 떠 있음(0/1), FD, RSS, 그 밖의 "키=값" 들
# 기본값은 아무 누수 없는 상태이고, 뒤의 "키=값" 이 덮어쓴다
snap() {
    # 앞의 고정 인자들
    local d="$1" n="$2" label="$3" round="$4" sess="$5" lr="$6" fd="$7" rss="$8"
    # 나머지는 덮어쓸 값
    shift 8
    # 기본값: 컨테이너 278 + 세션, 세션 폴더와 링크는 세션 수, state 49
    {
        echo "label=$label"; echo "seq=$n"; echo "round=$round"; echo "sessions=$sess"
        echo "time=2026-10-23T00:00:00+09:00"; echo "stable=1"; echo "loader_running=$lr"
        echo "loader_pid=$([[ $lr == 1 ]] && echo 4242)"; echo "loader_fd=$fd"; echo "loader_rss_kb=$rss"
        echo "cgroup_dirs=0"; echo "netns=0"; echo "veth=0"; echo "mounts=0"; echo "procs=0"; echo "zombies=0"
        echo "map_entries=0"; echo "ipt_filter=5"; echo "ipt_nat=5"; echo "work_dirs=0"; echo "unattributed=0"
        echo "container_dirs=$((278 + sess))"; echo "container_bytes=$((90000000 + sess * 1000))"
        echo "state_files=$((49 + sess / 4))"; echo "bycgroup_links=$sess"; echo "session_dirs=$sess"; echo "kill_sessions=$((sess / 4))"
        echo "write_tags=$([[ $lr == 1 ]] && echo 300)"
    } >"$d/$(printf '%03d' "$n")_$label.snap"
    # 덮어쓸 값이 있으면 그 줄을 바꾼다 (키=값)
    local kv k
    for kv in "$@"; do
        # 키
        k="${kv%%=*}"
        # 그 키의 줄을 통째로 바꾼다
        sed -i "s|^$k=.*|$kv|" "$d/$(printf '%03d' "$n")_$label.snap"
    done
}

# 합격하는 기본 세트를 만든다: 40 라운드, 라운드당 세션 4개(그중 kill 하나, 라운드마다 state 하나). 인자: 폴더. 마지막 스냅샷(end)에 덮어쓸 값을 뒤에 줄 수 있다
# 로더 FD: 고정분 20, 64칸이 찬 뒤 148 에서 멈춘다. RSS 는 후반부에 100kB 만 는다
base_set() {
    # 폴더
    local d="$1"
    shift
    # 폴더를 새로 만든다
    rm -rf "$d"; mkdir -p "$d"
    # 시작 전 (로더 없음)
    snap "$d" 1 start 0 0 0 "" ""
    # 로더 준비 직후 (고정분)
    snap "$d" 2 ready 0 0 1 20 5000
    # 10, 20, 30, 40 라운드
    snap "$d" 3 r10 10 40 1 100 6000
    snap "$d" 4 r20 20 80 1 148 6500
    snap "$d" 5 r30 30 120 1 148 6550
    snap "$d" 6 r40 40 160 1 148 6600
    # 끝 (덮어쓸 값 적용)
    snap "$d" 7 end 40 160 1 148 6600 "$@"
}

# compare 를 돌려 종료 코드와 FAIL 항목 목록을 확인한다. 인자: 설명, 기대 종료 코드, 기대 FAIL 항목(공백 구분, 없으면 ""), 폴더, [compare 옵션...]
check() {
    # 설명, 기대 코드, 기대 FAIL 목록, 폴더
    local msg="$1" want="$2" wantfail="$3" d="$4" got fails
    shift 4
    # 비교를 돌린다
    "$LC" compare "$@" "$d" >"$OUT" 2>&1
    # 종료 코드
    got=$?
    # FAIL 줄의 둘째 칸(항목)을 이름순으로 모은다
    fails="$(awk '$1 == "FAIL" {print $2}' "$OUT" | sort | tr '\n' ' ' | sed 's/ $//')"
    # 종료 코드와 FAIL 목록이 모두 기대와 같아야 한다
    if [[ "$got" == "$want" && "$fails" == "$wantfail" ]]; then
        printf '  PASS  %s\n' "$msg"
    else
        # 무엇이 달랐는지와 출력 전체를 보여 준다
        printf '  FAIL  %s (기대 rc=%s FAIL=[%s], 실제 rc=%s FAIL=[%s])\n' "$msg" "$want" "$wantfail" "$got" "$fails"
        sed 's/^/        /' "$OUT"
        failures=$((failures + 1))
    fi
}

# 출력에 문구가 있는지 본다 (마지막 check 의 출력). 인자: 설명, 문구
expect_text() {
    # 글자 그대로 찾는다
    if grep -qF -- "$2" "$OUT"; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (출력에 "%s" 없음)\n' "$1" "$2"; sed 's/^/        /' "$OUT"; failures=$((failures + 1)); fi
}

echo "[합격]"
base_set "$T/ok"
check "기본 세트는 합격 (rc 0, FAIL 없음)" 0 "" "$T/ok"
expect_text "결과 줄" "[leak_check] 결과: 합격"
expect_text "로더 값을 전부 보여 줌" "r40(r40,s160):fd=148,rss=6600"

echo "[엄격 0 증가: 항목 하나만 +1]"
# 항목마다 마지막 스냅샷의 값을 하나 올린다
for k in cgroup_dirs netns veth mounts procs zombies map_entries ipt_filter ipt_nat work_dirs unattributed; do
    # 원래 값 (iptables 는 5, 나머지는 0)
    v=0; [[ $k == ipt_* ]] && v=5
    # 세트를 만들고 그 항목만 바꾼다
    base_set "$T/m_$k" "$k=$((v + 1))"
    # 정확히 그 항목만 FAIL
    check "$k 가 1 늘면 그 항목만 FAIL" 1 "$k" "$T/m_$k"
done
# 줄어드는 것도 0 증가가 아니므로 FAIL
base_set "$T/m_dec" "ipt_nat=4"
check "iptables nat 가 줄어도 FAIL (0 변화만 합격)" 1 "ipt_nat" "$T/m_dec"

echo "[감시 맵: 시작 전 항목이 남아 있으면 경고만]"
base_set "$T/m_mapbase"
# 모든 스냅샷의 맵 항목을 3 으로 (차이는 0)
sed -i 's/^map_entries=.*/map_entries=3/' "$T/m_mapbase"/*.snap
check "시작 전 3개, 끝 3개면 합격" 0 "" "$T/m_mapbase"
expect_text "경고를 보여 줌" "경고: 시작 전 항목 3 개"

echo "[정확히 선형: 증가량 = 세션 수]"
for k in container_dirs session_dirs bycgroup_links; do
    # 원래 끝 값
    case $k in container_dirs) v=$((278 + 160)) ;; *) v=160 ;; esac
    # 하나 더 많게
    base_set "$T/l_$k" "$k=$((v + 1))"
    check "$k 가 세션 수보다 1 많으면 그 항목만 FAIL" 1 "$k" "$T/l_$k"
    # 하나 적게
    base_set "$T/l2_$k" "$k=$((v - 1))"
    check "$k 가 세션 수보다 1 적으면 그 항목만 FAIL" 1 "$k" "$T/l2_$k"
done

echo "[state 파일: 증가량 = kill 세션 수 증가량]"
# 기본 세트: kill 40, state +40 이라 합격 (위 [합격] 에서 이미 확인). 값이 보이는지만 본다
check "kill 40, state +40 이면 합격" 0 "" "$T/ok"
expect_text "kill 세션 기준값을 보여 줌" "meta.json exit_code 137 인 세션"
# state 가 kill 보다 하나 많다 (정상 경로에서 state 가 샘)
base_set "$T/s_hi" "state_files=$((49 + 41))"
check "state 증가가 kill 수보다 1 많으면 그 항목만 FAIL" 1 "state_files" "$T/s_hi"
# state 가 kill 보다 하나 적다
base_set "$T/s_lo" "state_files=$((49 + 39))"
check "state 증가가 kill 수보다 1 적으면 그 항목만 FAIL" 1 "state_files" "$T/s_lo"
# 예전 범위 기준이면 합격이던 경우: kill 은 40 인데 state 가 세션 수(160)만큼 늘었다
base_set "$T/s_all" "state_files=$((49 + 160))"
check "state 가 세션 수만큼 늘어도 kill 수와 다르면 FAIL (정상 경로 누수)" 1 "state_files" "$T/s_all"
# kill 이 하나도 없고 state 도 그대로면 합격
base_set "$T/s_zero" "state_files=49" "kill_sessions=0"
sed -i 's/^state_files=.*/state_files=49/; s/^kill_sessions=.*/kill_sessions=0/' "$T/s_zero"/*.snap
check "kill 0, state 0 증가면 합격" 0 "" "$T/s_zero"
# kill 세션 수가 기대보다 하나 많다 (state 는 그대로) -> state 행만 FAIL
base_set "$T/s_k41" "kill_sessions=41"
check "kill 수가 1 많고 state 가 그대로면 state 행만 FAIL" 1 "state_files" "$T/s_k41"
# kill 세션 수가 비었다
base_set "$T/s_empty" "kill_sessions="
check "kill 세션 수가 비면 rc 2" 2 "" "$T/s_empty"
expect_text "kill 세션 수를 못 읽었다고 알림" "kill 세션 수를 읽지 못해 판정할 수 없음"

echo "[snapshot 의 kill 세션 수 읽기 (가짜 세션 루트, sudo 불필요)]"
# 가짜 세션 루트: exit_code 137 둘, 0 하나, exit_code 없는 것 하나
KS="$T/ks_root"
mkdir -p "$KS/a" "$KS/b" "$KS/c" "$KS/d" "$T/ks_out"
echo '{"exit_code":137}' >"$KS/a/meta.json"
echo '{"exit_code":137}' >"$KS/b/meta.json"
echo '{"exit_code":0}' >"$KS/c/meta.json"
echo '{"session_id":"d"}' >"$KS/d/meta.json"
# 스냅샷을 찍는다 (안정화 대기는 짧게, 로더 없음)
MYC_LEAK_STABLE_TRIES=2 MYC_LEAK_SESS_ROOT="$KS" MYC_LEAK_LOADER_PID="" "$LC" snapshot "$T/ks_out" k1 0 0 >/dev/null 2>&1
# kill_sessions 줄을 읽는다
got="$(sed -n 's/^kill_sessions=//p' "$T/ks_out"/001_k1.snap 2>/dev/null)"
[[ "$got" == 2 ]] && echo "  PASS  exit_code 137 인 meta.json 만 센다 (2)" || { echo "  FAIL  kill 세션 수가 2 가 아님: '$got'"; failures=$((failures + 1)); }
# JSON 이 깨진 meta.json 이 하나 있으면 빈 값 (판정 불가로 이어진다)
echo '{"exit_code":' >"$KS/d/meta.json"
MYC_LEAK_STABLE_TRIES=2 MYC_LEAK_SESS_ROOT="$KS" MYC_LEAK_LOADER_PID="" "$LC" snapshot "$T/ks_out" k2 0 0 >/dev/null 2>&1
got="$(sed -n 's/^kill_sessions=//p' "$T/ks_out"/002_k2.snap 2>/dev/null)"
[[ -z "$got" ]] && grep -q '^kill_sessions=$' "$T/ks_out"/002_k2.snap && echo "  PASS  깨진 meta.json 이 있으면 빈 값" || { echo "  FAIL  깨진 meta.json 인데 값이 '$got'"; failures=$((failures + 1)); }

echo "[로더 FD]"
# 후반부(라운드 20 이상)에서 30 라운드 스냅샷만 150 으로 (148 -> 150 -> 148: 증가 합 2)
base_set "$T/f_late"
sed -i 's/^loader_fd=.*/loader_fd=150/' "$T/f_late/005_r30.snap"
check "후반부 스냅샷 사이 FD 가 늘면 그 항목만 FAIL" 1 "loader_fd_late" "$T/f_late"
# 전반부(10 라운드)의 증가는 포화 전이라 괜찮다 (기본 세트가 이미 20 -> 100 -> 148)
# 상한 초과: 후반부 전부 160 (고정분 20 + 132 = 152 초과, 후반부 증가는 0)
base_set "$T/f_max" "loader_fd=160"
sed -i 's/^loader_fd=.*/loader_fd=160/' "$T/f_max/004_r20.snap" "$T/f_max/005_r30.snap" "$T/f_max/006_r40.snap"
check "FD 가 고정분 + 132 를 넘으면 그 항목만 FAIL" 1 "loader_fd_max" "$T/f_max"
# 같은 세트를 상한 여유 옵션으로 넓히면 합격
check "--fd-extra 140 이면 같은 세트가 합격" 0 "" "$T/f_max" --fd-extra 140
# 후반부 스냅샷이 하나뿐이면 판정 불가
base_set "$T/f_few"
# 10 라운드 뒤 스냅샷들을 지우고 end 만 남긴다 (후반부 = end 하나)
rm -f "$T/f_few/004_r20.snap" "$T/f_few/005_r30.snap" "$T/f_few/006_r40.snap"
check "후반부 로더 스냅샷이 하나뿐이면 판정 불가 (rc 2)" 2 "" "$T/f_few"

echo "[로더 FD: 세션 칸(64) 포화 전후]"
# 로더 FD 만 바꾼 세트를 만든다. 인자: 폴더, 그 뒤로 "라벨:라운드:세션:FD" 를 차례로 (로더 시작 전 스냅샷은 자동으로 맨 앞에 둔다)
fd_set() {
    # 폴더
    local d="$1" n=1 spec label round sess fd
    shift
    # 폴더를 새로 만든다
    rm -rf "$d"; mkdir -p "$d"
    # 시작 전 (로더 없음)
    snap "$d" "$n" start 0 0 0 "" ""
    # 나머지 스냅샷 (RSS 는 일정하게 둔다)
    for spec in "$@"; do
        # 순번을 올린다
        n=$((n + 1))
        # 콜론으로 나눈다
        IFS=: read -r label round sess fd <<<"$spec"
        # 로더가 떠 있는 스냅샷
        snap "$d" "$n" "$label" "$round" "$sess" 1 "$fd" 5000
    done
}
# (a) 짧은 실행: 세션 0, 5, 10 에서 FD 17, 27, 37 (세션당 +2). 칸이 차기 전이라 미판정이고 전체는 합격
fd_set "$T/s_short" ready:0:0:17 r5:5:5:27 r10:10:10:37 end:10:10:37
check "(a) 세션 10 까지 FD 가 늘어도 loader_fd_late 는 FAIL 이 아님 (합격)" 0 "" "$T/s_short"
expect_text "(a) 미판정을 INFO 로 알림" "미판정 (슬롯 포화 전: 세션 10 < 64)"
# (b) 세션 150, FD 가 145 에서 멈춤 -> 판정해서 합격
fd_set "$T/s_sat" ready:0:0:17 r10:10:50:117 r20:20:100:145 r30:30:150:145 end:30:150:145
check "(b) 포화 뒤 FD 가 145 에서 멈추면 합격" 0 "" "$T/s_sat"
expect_text "(b) loader_fd_late 를 판정해 PASS" "PASS loader_fd_late"
# (c) 포화 뒤에도 늘어남: 세션 64 에서 145, 100 에서 160 -> FAIL (160 은 상한 17+132=149 도 넘으므로 loader_fd_max 도 FAIL)
fd_set "$T/s_grow" ready:0:0:17 r10:10:32:81 r20:20:64:145 r30:30:100:160 end:30:100:160
check "(c) 포화 뒤에도 FD 가 늘면 loader_fd_late FAIL (상한도 넘어 loader_fd_max 도 FAIL)" 1 "loader_fd_late loader_fd_max" "$T/s_grow"
# (c2) 같은 모양을 상한 안에서: 세션 64 에서 140, 100 에서 148 -> loader_fd_late 만 FAIL
fd_set "$T/s_grow2" ready:0:0:17 r10:10:32:81 r20:20:64:140 r30:30:100:148 end:30:100:148
check "(c2) 포화 뒤 증가가 상한 안이어도 loader_fd_late 만 FAIL" 1 "loader_fd_late" "$T/s_grow2"
# (d) 경계: 후반부 쌍이 하나(mid -> end)뿐이고 앞쪽(mid)의 세션이 64 면 판정, 63 이면 미판정
fd_set "$T/s_b64" ready:0:0:17 mid:10:64:140 end:20:74:142
check "(d) 앞쪽 스냅샷 세션 64 면 판정 (증가 2 -> FAIL)" 1 "loader_fd_late" "$T/s_b64"
fd_set "$T/s_b63" ready:0:0:17 mid:10:63:140 end:20:73:142
check "(d) 앞쪽 스냅샷 세션 63 이면 미판정 (합격)" 0 "" "$T/s_b63"
expect_text "(d) 63 의 미판정 안내" "미판정 (슬롯 포화 전: 세션 63 < 64)"

echo "[로더 RSS]"
base_set "$T/r_up" "loader_rss_kb=$((6500 + 1025))"
check "후반부 RSS 증가가 1024kB 를 넘으면 그 항목만 FAIL" 1 "loader_rss_kb" "$T/r_up"
base_set "$T/r_edge" "loader_rss_kb=$((6500 + 1024))"
check "후반부 RSS 증가가 정확히 1024kB 면 합격" 0 "" "$T/r_edge"
check "--rss-limit-kb 2048 이면 1025kB 증가도 합격" 0 "" "$T/r_up" --rss-limit-kb 2048

echo "[판정 불가 (rc 2)]"
# 엄격 항목 값이 비었다
base_set "$T/e_map" "map_entries="
check "맵 항목 수가 비면 rc 2" 2 "" "$T/e_map"
expect_text "빈 값을 알림" "값이 비었거나 읽지 못함"
# iptables 를 못 읽었다 (root 가 아닐 때처럼)
base_set "$T/e_ipt" "ipt_filter="
check "iptables 줄 수가 비면 rc 2" 2 "" "$T/e_ipt"
# 선형 항목이 비었다
base_set "$T/e_lin" "session_dirs="
check "세션 폴더 수가 비면 rc 2" 2 "" "$T/e_lin"
# 로더가 떠 있었는데 FD 가 비었다
base_set "$T/e_fd" "loader_fd="
check "로더가 떠 있던 스냅샷의 FD 가 비면 rc 2" 2 "" "$T/e_fd"
# 다른 항목이 FAIL 이어도 빈 값이 있으면 2 가 우선이다
base_set "$T/e_mix" "netns=1" "veth="
check "FAIL 과 빈 값이 섞이면 rc 2 (판정 불가 우선)" 2 "netns" "$T/e_mix"
# 안정되지 않은 스냅샷
base_set "$T/e_stable" "stable=0"
check "안정되지 않은 스냅샷이 있으면 rc 2" 2 "" "$T/e_stable"
# 스냅샷이 하나뿐
mkdir -p "$T/e_one"; snap "$T/e_one" 1 start 0 0 0 "" ""
check "스냅샷이 하나뿐이면 rc 2" 2 "" "$T/e_one"
# 폴더가 없다
check "저장 폴더가 없으면 rc 2" 2 "" "$T/no_such"
# 세션 값이 깨졌다
base_set "$T/e_sess" "sessions=abc"
check "세션 수가 정수가 아니면 rc 2" 2 "" "$T/e_sess"

echo "[사용 오류]"
# 하위 명령 없음
"$LC" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && echo "  PASS  하위 명령이 없으면 rc 2" || { echo "  FAIL  하위 명령이 없는데 rc=$rc"; failures=$((failures + 1)); }
# snapshot 인자 부족
"$LC" snapshot "$T" only_label >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && echo "  PASS  snapshot 인자가 부족하면 rc 2" || { echo "  FAIL  snapshot 인자 부족인데 rc=$rc"; failures=$((failures + 1)); }
# snapshot 라운드가 정수가 아님
"$LC" snapshot "$T" lab x 0 >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && echo "  PASS  snapshot 라운드가 정수가 아니면 rc 2" || { echo "  FAIL  snapshot 라운드 오류인데 rc=$rc"; failures=$((failures + 1)); }
# compare 기준값이 정수가 아님
"$LC" compare --fd-extra abc "$T/ok" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && echo "  PASS  --fd-extra 가 정수가 아니면 rc 2" || { echo "  FAIL  --fd-extra 오류인데 rc=$rc"; failures=$((failures + 1)); }

echo
# 결과
if [[ $failures -eq 0 ]]; then echo "ALL PASSED (실패 0)"; exit 0; fi
echo "FAILED (실패 $failures)"
exit 1
