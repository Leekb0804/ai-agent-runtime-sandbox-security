#!/bin/bash
#
# src/build.sh
#
# ===== 이 파일의 역할 =====
# eBPF 오브젝트, skeleton, 로더, 단위 테스트를 정해진 순서대로 한 번에 빌드한다.
#
# ===== 왜 스크립트로 묶나 =====
# watcher.bpf.c 를 수정하면 반드시 (1) clang -> (2) skeleton 재생성 -> (3) 로더 재컴파일
# 순서로 다시 해야 한다. skeleton 에 옛 바이트코드가 내장되어 있어서, 하나라도 빼먹으면
# "고쳤는데 옛날 프로그램이 로드되는" 문제가 생긴다. 이 순서를 사람이 매번 기억하지 않게 한다.
#
# 사용법: chmod +x build.sh && ./build.sh

# set -e : 어떤 명령이든 실패하면 스크립트를 즉시 중단한다.
# 앞 단계(예: clang)가 실패했는데 뒤 단계가 옛 파일로 계속 진행되는 것을 막는다.
set -e

# 스크립트가 있는 디렉토리(src/)로 이동한다. 어느 위치에서 실행해도 상대 경로가 맞게 하려는 것이다.
# dirname "$0" = 이 스크립트의 디렉토리, $(...) = 그 출력을 값으로 사용
cd "$(dirname "$0")"

echo "[1/4] eBPF 오브젝트 (clang)"
# -g                       : 디버그 정보 포함 (BTF 생성에 필요)
# -O2                      : 최적화. eBPF 는 최적화 없이는 verifier 를 통과하지 못하는 경우가 많다
# -target bpf              : x86 이 아니라 BPF 바이트코드로 컴파일
# -D__TARGET_ARCH_arm64    : 이 VM 의 CPU 구조(aarch64). 아키텍처별 매크로가 이 값을 참조한다
# -I bpf                   : "event.h", "vmlinux.h" 를 bpf/ 디렉토리에서 찾도록
# -Wno-missing-declarations: vmlinux.h 에서 나오는 무해한 경고 5개를 숨김
clang -g -O2 -target bpf -D__TARGET_ARCH_arm64 -I bpf \
      -Wno-missing-declarations -c bpf/watcher.bpf.c -o watcher.bpf.o

echo "[2/4] skeleton 생성"
# .o 에서 로드/어태치 함수와 바이트코드 배열을 담은 C 헤더(watcher.skel.h)를 만든다.
# 로더가 이 헤더를 include 하므로 로더 컴파일보다 먼저 실행해야 한다.
bpftool gen skeleton watcher.bpf.o > watcher.skel.h

echo "[3/4] 로더 (myc_loader)"
# detectors/*.c 는 셸 와일드카드로 "그 디렉토리의 모든 .c 파일"로 확장된다.
# 그래서 탐지기 파일을 detectors/ 에 추가하는 것만으로 빌드에 포함된다 (스크립트 수정 불필요).
#
# 주의: 정적 라이브러리(.a)로 묶으면 안 된다. 탐지기 파일은 생성자로 스스로 등록하기 때문에
#       다른 코드가 그 파일의 심볼을 참조하지 않는다. 라이브러리에 넣으면 링커가 "안 쓰는 파일"로
#       판단해 통째로 빼 버리고, 그러면 등록이 일어나지 않는다. 그래서 .c 를 직접 나열한다.
#
# -Wall -Wextra : 경고를 넓게 켜서 실수를 일찍 잡는다
# -I.           : src/ 에서 "bpf/event.h" 와 "watcher.skel.h" 를 찾도록
# -Iloader      : loader/ 에서 "detector.h", "dispatcher.h" 를 찾도록
# -lbpf -lelf -lz : libbpf 와 그 의존 라이브러리 링크
gcc -Wall -Wextra -I. -Iloader -o myc_loader \
    loader/loader.c loader/dispatcher.c loader/json_escape.c loader/detectors/*.c \
    -lbpf -lelf -lz

echo "[4/4] 단위 테스트 (test_dispatcher)"
# 테스트는 커널과 libbpf 가 필요 없고, dummy 탐지기도 링크하지 않는다 (테스트 전용 탐지기를 직접 등록).
gcc -Wall -Wextra -I. -Iloader -o test_dispatcher \
    loader/test_dispatcher.c loader/dispatcher.c loader/json_escape.c

echo "빌드 완료. 테스트: ./test_dispatcher  /  실행: sudo ./myc_loader"
