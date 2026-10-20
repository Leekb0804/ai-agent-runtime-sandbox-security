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
set -e

# 스크립트가 있는 디렉토리(src/)로 이동한다. 어느 위치에서 실행해도 상대 경로가 맞게 하려는 것이다.
cd "$(dirname "$0")"

# 로더와 테스트가 공통으로 쓰는 소스.
#   dispatcher.c    : 탐지기 등록과 분배
#   json_escape.c   : 로그 문자열 이스케이프
#   jsonl.c         : 로그 한 줄(JSON Lines) 생성
#   session_log.c   : cgroup_id -> 세션 변환과 세션별 로그 파일
#   kill.c          : kill switch (결과 기록과 감시 해제 콜백)
#   kill_cgroup.c   : 세션 cgroup 을 inode 확인 뒤 cgroup.kill 로 종료
#   verdict_handler.c : 판정 수집기
# 세션 로그 계열과 kill 계열을 나눠 둔다. test_verdict_handler 는 진짜 kill 대신 가짜를 링크하기 때문이다
# (진짜 kill 은 /sys/fs/cgroup 을 연다).
LOG_SRCS="loader/dispatcher.c loader/json_escape.c loader/jsonl.c loader/session_log.c"
KILL_SRCS="loader/kill.c loader/kill_cgroup.c"
COMMON_SRCS="$LOG_SRCS $KILL_SRCS loader/verdict_handler.c"

echo "[1/10] eBPF 오브젝트 (clang)"
# -g                       : 디버그 정보 포함 (BTF 생성에 필요)
# -O2                      : 최적화. eBPF 는 최적화 없이는 verifier 를 통과하지 못하는 경우가 많다
# -target bpf              : BPF 바이트코드로 컴파일
# -D__TARGET_ARCH_arm64    : 이 VM 의 CPU 구조(aarch64)
# -I bpf                   : "event.h", "vmlinux.h" 를 bpf/ 에서 찾도록
# -Wno-missing-declarations: vmlinux.h 에서 나오는 무해한 경고를 숨김
clang -g -O2 -target bpf -D__TARGET_ARCH_arm64 -I bpf \
      -Wno-missing-declarations -c bpf/watcher.bpf.c -o watcher.bpf.o

echo "[2/10] skeleton 생성"
bpftool gen skeleton watcher.bpf.o > watcher.skel.h

echo "[3/10] 로더 (myc_loader)"
# detectors/*.c 는 셸 와일드카드로 그 디렉토리의 모든 .c 로 확장된다.
# 탐지기 파일을 추가하는 것만으로 빌드에 포함된다 (스크립트 수정 불필요).
#
# 주의: 정적 라이브러리(.a)로 묶으면 안 된다. 탐지기 파일은 생성자로 스스로 등록하기 때문에
#       다른 코드가 그 파일의 심볼을 참조하지 않는다. 라이브러리에 넣으면 링커가 빼 버린다.
#
# -I.      : src/ 에서 "bpf/event.h", "watcher.skel.h" 를 찾도록
# -Iloader : loader/ 에서 "detector.h" 등을 찾도록 (detectors/ 안의 파일이 필요로 함)
gcc -Wall -Wextra -I. -Iloader -o myc_loader \
    loader/loader.c $COMMON_SRCS loader/detectors/*.c \
    -lbpf -lelf -lz

echo "[4/10] 단위 테스트: 디스패처 (test_dispatcher)"
# 검증 대상만 링크. 실제 탐지기(detectors/*.c)는 섞지 않는다 (테스트용 탐지기를 직접 등록).
gcc -Wall -Wextra -I. -Iloader -o test_dispatcher \
    loader/test_dispatcher.c loader/dispatcher.c loader/json_escape.c

echo "[5/10] 단위 테스트: 판정 처리와 세션 로그 (test_verdict_handler)"
# 이 테스트도 커널과 libbpf 가 필요 없다. 임시 디렉토리에 가짜 세션을 만들어 검증한다.
# kill.c 대신 테스트 파일 안의 가짜 kill_session 을 쓴다 (결과를 정해 둘 수 있고, 진짜 cgroup 에 닿지 않는다).
gcc -Wall -Wextra -I. -Iloader -o test_verdict_handler \
    loader/test_verdict_handler.c $LOG_SRCS loader/verdict_handler.c

echo "[6/10] 단위 테스트: write_exec_boundary 탐지기 (test_write_exec_boundary)"
# 실제 탐지기 파일 하나만 링크한다 (생성자로 자동 등록됨). 다른 탐지기를 섞으면 판정이 달라진다.
gcc -Wall -Wextra -I. -Iloader -o test_write_exec_boundary \
    loader/test_write_exec_boundary.c loader/dispatcher.c loader/detectors/write_exec_boundary.c

echo "[7/10] 단위 테스트: 로더 잠금 (test_loader_lock)"
# 커널 프로그램, libbpf, sudo 가 필요 없다. 임시 폴더에서 flock 잠금의 생존 확인을 검증한다.
gcc -Wall -Wextra -I. -Iloader -o test_loader_lock \
    loader/test_loader_lock.c

echo "[8/10] 단위 테스트: 세션 cgroup 종료 (test_kill)"
# 세션 로그와 libbpf 에 의존하지 않는 kill_cgroup.c 만 링크한다. 임시 폴더를 가짜 cgroup 루트로 쓴다.
gcc -Wall -Wextra -I. -Iloader -o test_kill \
    loader/test_kill.c loader/kill_cgroup.c

echo "[9/10] 단위 테스트: kill 결과 기록, 감시 해제, 관찰 모드 (test_kill_session)"
# 진짜 kill.c 와 세션 로그를 링크하고, 가짜 cgroup 루트를 kill_session_at 으로 넘긴다.
# --wrap=kill_cgroup_at : kill.c 의 kill_cgroup_at 호출이 테스트의 __wrap_kill_cgroup_at 으로 가게 한다
#                         (불렸는지 세고 진짜 함수 __real_kill_cgroup_at 을 부른다).
gcc -Wall -Wextra -I. -Iloader -o test_kill_session \
    loader/test_kill_session.c $LOG_SRCS $KILL_SRCS -Wl,--wrap=kill_cgroup_at

echo "[10/10] 단위 테스트: 로더 인자 해석 (test_loader_args)"
# 헤더(loader_args.h) 하나만 검증한다. MAX_DETECTORS 를 쓰려고 dispatcher.h 를 include 하지만 dispatcher.c 는 링크하지 않는다.
gcc -Wall -Wextra -I. -Iloader -o test_loader_args \
    loader/test_loader_args.c

echo "빌드 완료. 테스트: ./test_dispatcher && ./test_verdict_handler && ./test_write_exec_boundary && ./test_loader_lock && ./test_kill && ./test_kill_session && ./test_loader_args  /  실행: sudo ./myc_loader (더미 탐지기는 --detectors 로 명시해야 켜짐, 관찰 모드는 --no-kill)"
