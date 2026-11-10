#!/bin/bash
#
# tools/test_run_container.sh
#
# ===== 이 파일의 역할 =====
# src/run_container.sh 의 agent-run 이 세션 폴더에 쓰는 meta.json 을 root 없이 검증하는 단위 테스트.
# 시작 직후(가짜 mycontainer_run 이 불린 시점)와 정리 뒤(run_container.sh 가 끝난 뒤)의 권한, 키, 값을 본다.
# 커널, 컨테이너, eBPF, root 권한이 필요 없다. tools/mock/sandbox/ 의 가짜 명령을 PATH 앞에 둔 모래상자에서 돈다.
#
# ===== 모래상자 =====
# 실행마다 임시 폴더 아래에 새 모래상자를 만든다:
#   bin/        : tools/mock/sandbox/ 의 가짜 명령 (sudo, stat, jq, bpftool, ip, iptables, sysctl)
#   cg/         : 가짜 sudo, 가짜 stat 이 /sys/fs/cgroup 대신 쓰는 곳
#   containers/ : 가짜 sudo 가 /var/lib/mycontainer/containers 대신 쓰는 곳
#   sessions/   : MYC_SESSIONS_ROOT (세션 폴더와 meta.json 이 생기는 곳)
#   snap/       : run_container.sh 의 출력과, 가짜 mycontainer_run 이 적은 시작 직후 기록
#   work/       : src/run_container.sh 의 사본과 가짜 mycontainer_run. mycontainer_run.c 를 두지 않으므로
#                 run_container.sh 앞부분의 재컴파일 조건(-x, -nt)이 거짓이 되어 gcc 를 부르지 않는다.
#
# ===== 이 시험이 확인하지 못하는 것 =====
# - 가짜 sudo 는 root 가 아니라서 meta.json 의 소유자는 이 시험을 돌린 사용자다. 문서의 "소유자는 root" 는 VM 에서만 확인된다.
# - umask 는 이 시험이 0002 로 정한 것이라 실제 sudo 의 umask 와 다를 수 있다 (0002 는 chmod 600 이 빠지면 664 가 되어 드러나는 값이다).
# - 정리 단계의 sudo jq 는 이 모래상자에서 root 가 아니고 파일도 사용자 소유라서, 0600 root 소유 파일을 읽을 수 있는지 시험하지 못한다.
# - 모래상자에서는 CGROUP_PATH 가 /sys/fs/cgroup/... 그대로라 [[ -d "$CGROUP_PATH" ]] 가 거짓이다. 그래서 cgroup rmdir 재시도와
#   TERM/INT 의 cgroup.kill 은 실행되지 않는다. 가짜 ip 가 br0 이 있다고 답하므로 iptables, sysctl 도 불리지 않는다.
#
# ===== 종료 코드 =====
#   0 : 전부 통과 (ALL PASSED)
#   1 : 하나 이상 실패
#   2 : 준비 실패 (jq 나 stat 을 찾지 못함, 가짜 명령이나 run_container.sh 가 없음)
#
# 사용법: tools/test_run_container.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u
# 이 스크립트가 있는 폴더(tools)의 절대 경로
HERE="$(cd "$(dirname "$0")" && pwd)"
# 한 단계 위 폴더 = 저장소 루트
ROOT="$(cd "$HERE/.." && pwd)"
# 검사 대상 (모래상자의 work/ 로 복사해서 쓴다)
RUN_CONTAINER="$ROOT/src/run_container.sh"
# 가짜 명령 폴더
SANDBOX="$HERE/mock/sandbox"
# bin/ 에 넣을 가짜 명령 (mycontainer_run 은 work/ 에 따로 넣는다)
MOCK_BINS=(sudo stat jq bpftool ip iptables sysctl)

# 진짜 jq 와 stat 을 PATH 에서 찾는다 (가짜를 PATH 앞에 두기 전에 찾아야 가짜 자신을 찾지 않는다)
MOCK_REAL_JQ="$(command -v jq)" || MOCK_REAL_JQ=""
# 진짜 stat
MOCK_REAL_STAT="$(command -v stat)" || MOCK_REAL_STAT=""
# 둘 중 하나라도 없으면 시험을 할 수 없다
if [[ -z "$MOCK_REAL_JQ" || -z "$MOCK_REAL_STAT" ]]; then
    # 무엇을 찾지 못했는지 알린다
    echo "준비 실패: jq 또는 stat 을 PATH 에서 찾지 못함 (jq='$MOCK_REAL_JQ', stat='$MOCK_REAL_STAT')" >&2
    # 준비 실패로 끝낸다
    exit 2
fi
# 가짜 jq, 가짜 stat, 가짜 mycontainer_run 이 진짜 명령을 부를 때 쓴다
export MOCK_REAL_JQ MOCK_REAL_STAT
# 검사 대상과 가짜 명령이 모두 있는지 확인한다
for f in "$RUN_CONTAINER" "$SANDBOX/mycontainer_run" "${MOCK_BINS[@]/#/$SANDBOX/}"; do
    # 없으면 시험을 할 수 없다
    if [[ ! -f "$f" ]]; then
        # 어느 파일이 없는지 알린다
        echo "준비 실패: 파일이 없음: $f" >&2
        # 준비 실패로 끝낸다
        exit 2
    fi
done

# 실패한 검사 수
failures=0
# 모래상자들을 담을 임시 폴더
TMP="$(mktemp -d)"
# 어떻게 끝나든 이 시험이 만든 임시 폴더를 지운다 (test_judge.sh 와 같은 방식)
trap 'rm -rf "$TMP"' EXIT

# 값이 기대와 같은지 확인한다 (문자열 비교)
#   check_eq "<설명>" "<기대>" "<실제>"
check_eq() {
    # 설명, 기대, 실제
    local msg="$1" want="$2" got="$3"
    # 같으면 통과
    if [[ "$got" == "$want" ]]; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 기대, 실제
        printf '  FAIL  %s (기대 %s, 실제 %s)\n' "$msg" "$want" "$got"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 바로 앞 run_sb 의 출력(OUTF)에 문구가 있는지 확인한다 (tools/test_report.sh 의 expect_text 와 같은 형식)
#   expect_text "<설명>" "<문구>"
expect_text() {
    # 설명과 문구
    local msg="$1" text="$2"
    # 있으면 통과 (-F: 문구를 글자 그대로 찾는다)
    if grep -qF -- "$text" "$OUTF"; then
        # 통과 줄
        printf '  PASS  %s\n' "$msg"
    else
        # 실패 줄과 찾던 문구
        printf '  FAIL  %s (출력에 "%s" 가 없음)\n' "$msg" "$text"
        # run_container.sh 의 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUTF"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 모래상자를 새로 만들고 run_container.sh agent-run 을 한 번 실행한다. 결과는 아래 전역 변수에 둔다.
#   run_sb <이름> <가짜 mycontainer_run 의 종료 코드> [환경변수=값 ...]
# 결과:
#   RC_GOT     : run_container.sh 의 종료 코드
#   OUTF       : run_container.sh 의 출력(표준 출력과 표준 오류) 파일
#   SNAP_START : 가짜 mycontainer_run 이 적은 시작 직후 기록 파일
#   SESS_COUNT : 세션 루트에 생긴 세션 폴더 수 (by-cgroup 은 세지 않는다)
#   META       : 첫 세션 폴더의 meta.json 경로 (세션 폴더가 없으면 없는 경로)
run_sb() {
    # 이름과 종료 코드. 나머지 인자는 env 에 넘길 환경변수
    local label="$1" rc="$2" d dirs=()
    # 이름과 종료 코드를 인자에서 뺀다
    shift 2
    # 이 실행의 모래상자 폴더
    local sb="$TMP/$label"
    # 모래상자의 하위 폴더를 만든다
    mkdir -p "$sb/bin" "$sb/cg" "$sb/containers" "$sb/sessions" "$sb/snap" "$sb/work"
    # 가짜 명령을 bin/ 으로 복사한다
    for d in "${MOCK_BINS[@]}"; do cp "$SANDBOX/$d" "$sb/bin/$d"; done
    # 검사 대상 사본과 가짜 mycontainer_run 을 work/ 로 복사한다 (mycontainer_run.c 는 두지 않는다)
    cp "$RUN_CONTAINER" "$sb/work/run_container.sh"
    # 가짜 mycontainer_run
    cp "$SANDBOX/mycontainer_run" "$sb/work/mycontainer_run"
    # 복사한 파일에 실행 권한을 준다
    chmod +x "$sb/bin/"* "$sb/work/run_container.sh" "$sb/work/mycontainer_run"
    # 출력 파일
    OUTF="$sb/snap/out.txt"
    # 시작 직후 기록 파일
    SNAP_START="$sb/snap/start.txt"
    # 하위 셸에서 실행한다 (cd, umask, export 가 이 시험에 남지 않게)
    (
        # work/ 에서 실행해야 ./mycontainer_run 을 찾는다
        cd "$sb/work" || exit 2
        # 새 파일의 기본 권한 (664). 실제 sudo 의 umask 와 다를 수 있다 (머리 주석)
        umask 0002
        # 가짜 sudo, 가짜 stat 의 경로 바꾸기 기준
        export SB_ROOT="$sb"
        # 가짜 mycontainer_run 이 시작 직후를 적을 파일
        export SNAP_FILE="$SNAP_START"
        # 세션 폴더를 모래상자 안에 만든다
        export MYC_SESSIONS_ROOT="$sb/sessions"
        # 가짜 명령을 진짜보다 먼저 찾게 한다
        export PATH="$sb/bin:$PATH"
        # MYC_ROOTFS 를 지워 rootfs 검사를 건너뛰고(기본 경로는 가짜 mycontainer_run 이 쓰지 않는다), 넘긴 환경변수를 붙여 실행한다
        env -u MYC_ROOTFS "$@" ./run_container.sh agent-run -- "rc=$rc" /bin/sh -c 'echo hi'
    ) >"$OUTF" 2>&1
    # run_container.sh 의 종료 코드
    RC_GOT=$?
    # 세션 폴더(이름이 날짜로 시작)를 모은다. 맞는 것이 없으면 글자 그대로 남으므로 -d 로 거른다
    for d in "$sb/sessions"/2*/; do [[ -d "$d" ]] && dirs+=("${d%/}"); done
    # 세션 폴더 수
    SESS_COUNT=${#dirs[@]}
    # 첫 세션 폴더의 meta.json (없으면 없는 경로가 되어 아래 검사들이 "없음" 으로 본다)
    META="${dirs[0]:-$sb/sessions/세션폴더없음}/meta.json"
}

# 시작 직후 기록에서 키 하나의 값을 꺼낸다 (없으면 "기록없음")
#   snap_value <키>
snap_value() {
    # 키
    local key="$1" v
    # "키=값" 줄에서 값만 꺼낸다
    v="$(sed -n "s/^$key=//p" "$SNAP_START" 2>/dev/null)"
    # 비었으면 기록없음
    echo "${v:-기록없음}"
}

# 정리 뒤 meta.json 의 권한 (없으면 "없음")
end_perm() {
    # 있으면 8진수 권한, 없으면 없음
    if [[ -f "$META" ]]; then "$MOCK_REAL_STAT" -c '%a' "$META"; else echo "없음"; fi
}

# 정리 뒤 meta.json 에 jq 식을 적용한 결과 (없으면 "없음", jq 가 실패하면 "jq실패")
#   end_jq '<jq 식>'
end_jq() {
    # 파일이 없으면 없음
    if [[ ! -f "$META" ]]; then echo "없음"; return; fi
    # jq 결과 (-c 한 줄). 실패하면 jq실패
    "$MOCK_REAL_JQ" -c "$1" "$META" 2>/dev/null || echo "jq실패"
}

# 시작 직후 meta.json 의 키 (정렬, jq keys 의 모양)
START_KEYS='["cgroup_id","cgroup_path","command","limits","rootfs","schema_version","session_id","started_at"]'
# 정리 뒤 meta.json 의 키 (ended_at, exit_code 가 더해진다)
END_KEYS='["cgroup_id","cgroup_path","command","ended_at","exit_code","limits","rootfs","schema_version","session_id","started_at"]'

echo "[rc=0 실행: 시작 직후와 정리 뒤의 meta.json]"
# 가짜 mycontainer_run 이 0 으로 끝나는 실행
run_sb rc0 0
# run_container.sh 는 mycontainer_run 의 종료 코드로 끝난다
check_eq "rc=0: run_container.sh 종료 코드 0" 0 "$RC_GOT"
# 세션 폴더는 하나다
check_eq "rc=0: 세션 폴더가 하나 생김" 1 "$SESS_COUNT"
# 시작 직후 권한 (touch -> chmod 600 -> tee 순서라 내용이 들어가기 전에 600)
check_eq "rc=0: 시작 직후 meta.json 권한 600" 600 "$(snap_value start_perm)"
# 시작 직후 키 8개
check_eq "rc=0: 시작 직후 meta.json 키 8개" "$START_KEYS" "$(snap_value start_keys)"
# 정리 뒤 권한 (임시 파일을 600 으로 맞춘 뒤 mv 로 바꿔 넣는다)
check_eq "rc=0: 정리 뒤 meta.json 권한 600" 600 "$(end_perm)"
# 정리 뒤 키 10개
check_eq "rc=0: 정리 뒤 meta.json 키 10개 (ended_at, exit_code 추가)" "$END_KEYS" "$(end_jq 'keys')"
# exit_code 는 숫자 0
check_eq "rc=0: exit_code 0" 0 "$(end_jq '.exit_code')"
# 임시 파일이 남지 않는다 (mv 로 바꿔 넣었다)
check_eq "rc=0: meta.json.tmp 가 남지 않음" 없음 "$([[ -e "$META.tmp" ]] && echo 있음 || echo 없음)"
# 경고 줄([!])이 없다 (가짜 bpftool 의 lookup 이 254 라 감시 맵 정리도 조용하다)
check_eq "rc=0: 경고 줄([!])이 없음" 0 "$(grep -c '^\[!\]' "$OUTF")"
# 러너가 세션 폴더를 찾는 데 쓰는 줄이 정확히 한 번 나온다
check_eq "rc=0: \"[*] 세션 시작:\" 줄이 한 번" 1 "$(grep -cF '[*] 세션 시작:' "$OUTF")"

echo "[rc=0 실행: meta.json 의 값]"
# limits 는 객체
check_eq "limits 가 객체" '"object"' "$(end_jq '.limits | type')"
# 기본 제한값은 문자열 "max"
check_eq "limits.memory 가 \"max\"" '"max"' "$(end_jq '.limits.memory')"
# cpu
check_eq "limits.cpu 가 \"max\"" '"max"' "$(end_jq '.limits.cpu')"
# pids
check_eq "limits.pids 가 \"max\"" '"max"' "$(end_jq '.limits.pids')"
# 형식 버전은 숫자 1 (run_container.sh 의 META_SCHEMA_VERSION)
check_eq "schema_version 이 1" 1 "$(end_jq '.schema_version')"

echo "[rc=3 실행: 종료 코드가 meta.json 에 남음]"
# 가짜 mycontainer_run 이 3 으로 끝나는 실행
run_sb rc3 3
# run_container.sh 도 3 으로 끝난다
check_eq "rc=3: run_container.sh 종료 코드 3" 3 "$RC_GOT"
# exit_code 는 숫자 3
check_eq "rc=3: exit_code 3" 3 "$(end_jq '.exit_code')"
# 정리 뒤 권한
check_eq "rc=3: 정리 뒤 meta.json 권한 600" 600 "$(end_perm)"

echo "[시작 쓰기의 jq 실패 (MOCK_JQ_FAIL_START=1)]"
# 시작 쓰기의 jq -n 만 실패하는 실행
run_sb jqfail 0 MOCK_JQ_FAIL_START=1
# 경고만 내고 계속 진행하므로 mycontainer_run 의 종료 코드(0)로 끝난다
check_eq "jq 실패: run_container.sh 종료 코드 0" 0 "$RC_GOT"
# 시작 직후 meta.json 이 없다 (jq | tee 였다면 빈 파일이 생긴다). 기록 줄 "start_meta=없음 (경로)" 의 첫 낱말을 본다
# (기록 파일 자체가 없을 때 통과하지 않도록 start_perm 이 없는 것이 아니라 start_meta 가 있는 것을 확인한다)
SM="$(snap_value start_meta)"
# 첫 낱말이 없음 이어야 한다
check_eq "jq 실패: 시작 직후 meta.json 이 없음" 없음 "${SM%% *}"
# 정리 단계도 없는 meta.json 을 만들지 않는다
check_eq "jq 실패: 정리 뒤 meta.json 이 없음" 없음 "$(end_perm)"
# 경고 문구
expect_text "jq 실패: \"meta.json 생성 실패 (jq)\" 문구" "meta.json 생성 실패 (jq)"
# meta.json 이 없어도 세션 시작 줄은 한 번 나온다 (러너가 세션 폴더를 찾는다)
check_eq "jq 실패: \"[*] 세션 시작:\" 줄이 한 번" 1 "$(grep -cF '[*] 세션 시작:' "$OUTF")"

# 결과 요약
echo
# 실패가 없으면 통과
if [[ $failures -eq 0 ]]; then
    # 통과 줄
    echo "ALL PASSED (실패 0)"
    # 통과로 끝낸다
    exit 0
fi
# 실패 수
echo "FAILED (실패 $failures)"
# 실패로 끝낸다
exit 1
