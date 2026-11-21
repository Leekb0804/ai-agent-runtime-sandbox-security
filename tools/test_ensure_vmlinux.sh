#!/bin/bash
#
# tools/test_ensure_vmlinux.sh
#
# ===== 이 파일의 역할 =====
# src/ensure_vmlinux.sh (build.sh 가 [1/13] 앞에서 부르는 vmlinux.h 생성 단계)를 root 없이 검증하는 단위 테스트.
# 진짜 커널 BTF 와 진짜 bpftool 대신 가짜 BTF 파일과 가짜 bpftool 을 환경변수(MYC_BTF_PATH, BPFTOOL)로 넘긴다.
#
# ===== 모래상자 =====
# 검사마다 임시 폴더 아래에 새 모래상자를 만든다:
#   work/       : src/ensure_vmlinux.sh 의 사본과 빈 bpf/ (사본이 만드는 vmlinux.h 는 여기에 생긴다)
#   bin/bpftool : 가짜 bpftool. 받은 인자를 calls 에 한 줄씩 적고, FAKE_BPFTOOL_MODE 에 따라
#                 ok(헤더 두 줄 출력, 0), fail(한 줄 출력 뒤 1), empty(출력 없이 0) 로 끝난다
#   calls       : 가짜 bpftool 의 호출 흔적 (비어 있으면 불리지 않은 것)
#   out         : ensure_vmlinux.sh 의 출력(표준 출력과 표준 오류)
# 사본은 모래상자 밖(임시 폴더 루트)에서 실행한다. 스크립트가 자기 폴더로 cd 하는지도 함께 드러난다.
#
# ===== 이 시험이 확인하지 못하는 것 =====
# - 진짜 bpftool 의 출력 형식과 진짜 /sys/kernel/btf/vmlinux 읽기는 깨끗한 사본의 build.sh 로만 확인된다.
# - chmod 와 mv 의 순서(mv 뒤에 chmod 해도 최종 파일의 권한은 같다)
#
# ===== 종료 코드 =====
#   0 : 전부 통과 (ALL PASSED)
#   1 : 하나 이상 실패
#   2 : 준비 실패 (src/ensure_vmlinux.sh 가 없음)
#
# 사용법: tools/test_ensure_vmlinux.sh   (전부 통과하면 ALL PASSED, 종료 코드 0)

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u
# 이 스크립트가 있는 폴더(tools)의 절대 경로
HERE="$(cd "$(dirname "$0")" && pwd)"
# 한 단계 위 폴더 = 저장소 루트
ROOT="$(cd "$HERE/.." && pwd)"
# 검사 대상 (모래상자의 work/ 로 복사해서 쓴다)
SUBJECT="$ROOT/src/ensure_vmlinux.sh"

# 검사 대상이 없으면 시험을 할 수 없다
if [[ ! -f "$SUBJECT" ]]; then
    # 어느 파일이 없는지 알린다
    echo "준비 실패: 파일이 없음: $SUBJECT" >&2
    # 준비 실패로 끝낸다
    exit 2
fi

# 실패한 검사 수
failures=0
# 모래상자들을 담을 임시 폴더
TMP="$(mktemp -d)"
# 어떻게 끝나든 이 시험이 만든 임시 폴더를 지운다 (test_judge.sh 와 같은 방식)
trap 'rm -rf "$TMP"' EXIT

# 가짜 BTF 파일 (내용은 보지 않는다. 읽을 수 있기만 하면 된다)
BTF="$TMP/btf_vmlinux"
# 아무 내용이나 쓴다
echo "fake btf" >"$BTF"
# 생성할 때 나와야 하는 안내 줄
GUIDE="[*] bpf/vmlinux.h 가 없거나 비어 있어 현재 커널의 BTF 로 생성한다"
# 가짜 bpftool 이 ok 일 때 내는 내용 (vmlinux.h 가 이것과 같아야 한다)
FAKE_OK=$'/* fake vmlinux.h */\nstruct fake_btf { int x; };'

# 값이 기대와 같은지 확인한다 (tools/test_run_container.sh 의 check_eq 와 같은 형식)
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
        printf '  FAIL  %s (기대 %q, 실제 %q)\n' "$msg" "$want" "$got"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 바로 앞 run_ev 의 출력(OUTF)에 문구가 있는지 확인한다 (tools/test_report.sh 의 expect_text 와 같은 형식)
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
        # ensure_vmlinux.sh 의 출력을 들여써서 보여 준다
        sed 's/^/        /' "$OUTF"
        # 실패 수를 늘린다
        failures=$((failures + 1))
    fi
}

# 모래상자를 새로 만든다. 결과는 아래 전역 변수에 둔다 (run_ev 앞에 vmlinux.h 를 미리 둘 수 있게 나눈다)
#   mk_sb <이름>
# 결과:
#   SB    : 모래상자 폴더
#   WORK  : 사본이 있는 폴더 (WORK/bpf/vmlinux.h 가 만들어질 곳)
#   OUTF  : 출력 파일
#   CALLS : 가짜 bpftool 의 호출 흔적 파일
mk_sb() {
    # 이 검사의 모래상자 폴더
    SB="$TMP/$1"
    # 하위 폴더를 만든다
    mkdir -p "$SB/work/bpf" "$SB/bin"
    # 검사 대상 사본
    cp "$SUBJECT" "$SB/work/ensure_vmlinux.sh"
    # 가짜 bpftool (인자를 적고 모드에 따라 끝난다)
    cat >"$SB/bin/bpftool" <<'EOF'
#!/bin/bash
# 호출 흔적: 받은 인자를 한 줄로
echo "$*" >>"$FAKE_BPFTOOL_LOG"
# 모드에 따라 출력과 종료 코드를 정한다
case "${FAKE_BPFTOOL_MODE:-ok}" in
    ok) printf '%s\n' '/* fake vmlinux.h */' 'struct fake_btf { int x; };' ;;
    fail) echo '/* partial */'; exit 1 ;;
    empty) exit 0 ;;
esac
EOF
    # 실행 권한
    chmod +x "$SB/bin/bpftool"
    # 결과 변수
    WORK="$SB/work"
    OUTF="$SB/out"
    CALLS="$SB/calls"
    # 호출 흔적은 빈 파일로 시작한다
    : >"$CALLS"
}

# 바로 앞 mk_sb 의 사본을 한 번 실행한다. 가짜 BTF 와 가짜 bpftool 을 쓰고, 뒤의 환경변수가 앞을 덮는다
#   run_ev <가짜 bpftool 모드> [환경변수=값 ...]
# 결과: RC_GOT (종료 코드). 출력은 OUTF
run_ev() {
    # 모드. 나머지 인자는 env 에 넘길 환경변수
    local mode="$1"
    # 모드를 인자에서 뺀다
    shift
    # 모래상자 밖(임시 폴더 루트)에서 실행한다
    (cd "$TMP" && env FAKE_BPFTOOL_MODE="$mode" FAKE_BPFTOOL_LOG="$CALLS" MYC_BTF_PATH="$BTF" BPFTOOL="$SB/bin/bpftool" "$@" \
        bash "$WORK/ensure_vmlinux.sh") >"$OUTF" 2>&1
    # 바로 종료 코드를 저장한다
    RC_GOT=$?
}

# 파일이 있으면 yes, 없으면 no
exists() {
    # -e: 종류와 관계없이 있는지
    if [[ -e "$1" ]]; then echo yes; else echo no; fi
}

echo "(가) vmlinux.h 가 없으면 만든다"
mk_sb a
run_ev ok
check_eq "종료 코드 0" 0 "$RC_GOT"
check_eq "출력은 안내 줄 한 줄" "$GUIDE" "$(cat "$OUTF")"
check_eq "vmlinux.h 의 내용이 bpftool 출력과 같다" "$FAKE_OK" "$(cat "$WORK/bpf/vmlinux.h" 2>/dev/null)"
check_eq "bpftool 을 btf dump file <BTF> format c 로 한 번 부른다" "btf dump file $BTF format c" "$(cat "$CALLS")"
check_eq "bpf/ 에는 vmlinux.h 만 남는다 (임시 파일 없음)" "vmlinux.h" "$(ls -A "$WORK/bpf")"
check_eq "vmlinux.h 의 권한이 644" 644 "$(stat -c %a "$WORK/bpf/vmlinux.h" 2>/dev/null)"

echo "(나) 이미 있으면 bpftool 을 부르지 않는다"
mk_sb b
echo "existing header" >"$WORK/bpf/vmlinux.h"
run_ev ok
check_eq "종료 코드 0" 0 "$RC_GOT"
check_eq "출력 없음" "" "$(cat "$OUTF")"
check_eq "bpftool 호출 흔적 없음" "" "$(cat "$CALLS")"
check_eq "기존 vmlinux.h 의 내용이 그대로다" "existing header" "$(cat "$WORK/bpf/vmlinux.h")"

echo "(다) 빈 vmlinux.h 는 다시 만든다"
mk_sb c
: >"$WORK/bpf/vmlinux.h"
run_ev ok
check_eq "종료 코드 0" 0 "$RC_GOT"
check_eq "출력은 안내 줄 한 줄" "$GUIDE" "$(cat "$OUTF")"
check_eq "vmlinux.h 의 내용이 bpftool 출력과 같다" "$FAKE_OK" "$(cat "$WORK/bpf/vmlinux.h" 2>/dev/null)"

echo "(라) bpftool 이 실패하면 아무것도 남기지 않는다"
mk_sb d
run_ev fail
check_eq "종료 코드 1" 1 "$RC_GOT"
check_eq "vmlinux.h 가 없다" no "$(exists "$WORK/bpf/vmlinux.h")"
check_eq "bpf/ 가 비어 있다 (임시 파일 없음)" "" "$(ls -A "$WORK/bpf")"

echo "(마) bpftool 이 성공해도 출력이 비면 만들지 않는다"
mk_sb e
run_ev empty
check_eq "종료 코드 1" 1 "$RC_GOT"
check_eq "vmlinux.h 가 없다" no "$(exists "$WORK/bpf/vmlinux.h")"
check_eq "bpf/ 가 비어 있다 (임시 파일 없음)" "" "$(ls -A "$WORK/bpf")"

echo "(바) BTF 파일이 없으면 실패한다"
mk_sb f
run_ev ok MYC_BTF_PATH="$TMP/no_such_btf"
check_eq "종료 코드 1" 1 "$RC_GOT"
expect_text "BTF 파일 오류 메시지" "BTF 파일을 읽을 수 없다: $TMP/no_such_btf"
check_eq "bpftool 호출 흔적 없음" "" "$(cat "$CALLS")"

echo "(사) bpftool 이 없으면 실패한다"
mk_sb g
run_ev ok BPFTOOL="$SB/bin/no_such_bpftool"
check_eq "종료 코드 1" 1 "$RC_GOT"
expect_text "bpftool 오류 메시지" "bpftool 을 찾지 못했다: $SB/bin/no_such_bpftool"
check_eq "vmlinux.h 가 없다" no "$(exists "$WORK/bpf/vmlinux.h")"

echo
# 마지막: 실패한 검사가 없으면 종료 코드 0, 있으면 1.
if [[ $failures -eq 0 ]]; then
    echo "ALL PASSED (실패 0)"
    exit 0
fi
echo "FAILED (실패 $failures)"
exit 1
