#!/bin/bash
#
# src/ensure_vmlinux.sh
#
# ===== 이 파일의 역할 =====
# bpf/vmlinux.h 가 없거나 비어 있으면 현재 커널의 BTF 로 만든다. build.sh 가 [1/13] 앞에서 부른다.
# vmlinux.h 는 .gitignore 대상이라 깨끗한 clone 에는 없고, 없으면 [1/13] 의 clang 이 'vmlinux.h' file not found 로 실패한다.
#
# ===== 동작 =====
# - bpf/vmlinux.h 가 이미 있고 비어 있지 않으면 아무것도 출력하지 않고 끝난다 (종료 코드 0)
# - 없으면: BTF 파일을 읽을 수 있는지, bpftool 이 있는지 확인한 뒤, 같은 폴더의 임시 파일에
#   "bpftool btf dump file <BTF> format c" 를 쓴다. 성공하고 비어 있지 않을 때만 mv 로 bpf/vmlinux.h 로 바꾼다.
#   중간에 실패해도 반쯤 쓰인 vmlinux.h 가 남지 않게 하려는 것이다 (남으면 다음 빌드가 "이미 있음" 으로 건너뛴다).
#
# ===== 환경변수 (시험이 가짜를 쓰게 하려는 것) =====
#   MYC_BTF_PATH : BTF 파일 (기본 /sys/kernel/btf/vmlinux)
#   BPFTOOL      : bpftool 명령 이름이나 경로 (기본 bpftool)
#
# ===== 종료 코드 =====
#   0 : vmlinux.h 가 이미 있거나 새로 만들었음
#   1 : 만들지 못함 (BTF 파일이 없음, bpftool 이 없음, bpftool 실패, 출력이 비어 있음)
#
# 사용법: ./ensure_vmlinux.sh   (시험: tools/test_ensure_vmlinux.sh)

# 값이 정해지지 않은 변수를 쓰면 멈춘다
set -u

# 스크립트가 있는 디렉토리(src/)로 이동한다 (build.sh 와 같은 방식. bpf/ 상대 경로가 맞게)
cd "$(dirname "$0")" || exit 1

# 만들 파일
OUT="bpf/vmlinux.h"
# 읽을 BTF 파일
BTF="${MYC_BTF_PATH:-/sys/kernel/btf/vmlinux}"
# 쓸 bpftool
BPFTOOL="${BPFTOOL:-bpftool}"

# 이미 있고 비어 있지 않으면 할 일이 없다 (출력 없음)
if [[ -s "$OUT" ]]; then
    exit 0
fi

# BTF 파일을 읽을 수 없으면 만들 수 없다
if [[ ! -r "$BTF" ]]; then
    # 무엇이 없는지 알린다
    echo "[ensure_vmlinux] BTF 파일을 읽을 수 없다: $BTF (BTF 가 켜진 커널이 필요하다. 다른 파일은 MYC_BTF_PATH 로 지정)" >&2
    exit 1
fi

# bpftool 이 없으면 만들 수 없다
if ! command -v "$BPFTOOL" >/dev/null 2>&1; then
    # 무엇이 없는지 알린다
    echo "[ensure_vmlinux] bpftool 을 찾지 못했다: $BPFTOOL (bpftool 을 설치하거나 BPFTOOL 로 경로 지정)" >&2
    exit 1
fi

# 만든다는 안내 (생성할 때만 나온다)
echo "[*] bpf/vmlinux.h 가 없거나 비어 있어 현재 커널의 BTF 로 생성한다"

# 같은 폴더의 임시 파일 (같은 파일시스템이라 mv 가 한 번에 바뀐다)
TMP_OUT="$(mktemp "$OUT.tmp.XXXXXX")" || exit 1
# 어떻게 끝나든 임시 파일을 지운다 (mv 로 바꾼 뒤에는 없는 파일이라 아무 일도 없다)
trap 'rm -f "$TMP_OUT"' EXIT

# BTF 를 C 헤더로 쓴다. 실패하면 vmlinux.h 를 만들지 않는다
if ! "$BPFTOOL" btf dump file "$BTF" format c >"$TMP_OUT"; then
    # 실패를 알린다
    echo "[ensure_vmlinux] bpftool btf dump 가 실패했다: $BPFTOOL btf dump file $BTF format c" >&2
    exit 1
fi

# 성공해도 출력이 비어 있으면 만들지 않는다
if [[ ! -s "$TMP_OUT" ]]; then
    # 빈 출력을 알린다
    echo "[ensure_vmlinux] bpftool btf dump 의 출력이 비어 있다: $BTF" >&2
    exit 1
fi

# mktemp 는 0600 으로 만들므로, 다른 사용자도 읽을 수 있게 0644 로 바꾼다
chmod 0644 "$TMP_OUT" || exit 1

# 다 쓴 임시 파일을 vmlinux.h 로 바꾼다
mv "$TMP_OUT" "$OUT" || exit 1
