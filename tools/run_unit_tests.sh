#!/bin/bash
#
# tools/run_unit_tests.sh [--skip-build]
#
# ===== 이 파일의 역할 =====
# root 가 필요 없는 시험을 한 번에 돌린다: C 단위 시험(src/build.sh 로 빌드한 바이너리)과 셸 단위 시험(tools/test_*.sh).
# 시나리오(sudo ./run_scenarios.sh)는 root 와 VM(커널, 컨테이너)이 필요해서 포함하지 않는다.
# 시험 하나가 실패해도 나머지를 계속 돌리고, 끝에 시험마다 통과/실패, 종료 코드, PASS 개수를 요약한다.
# 시험 목록은 이 파일의 TESTS 배열이 정한다. 목록에서 시험이 빠져도 종료 코드는 0 이므로, 이 도구는 목록에 있는 시험이 통과했는지만 보증한다.
#
# ===== 옵션 =====
#   --skip-build  : src/build.sh 를 건너뛰고 이미 빌드한 바이너리를 쓴다 (없으면 그 시험은 실패로 센다)
#
# ===== 종료 코드 =====
#   0 : 전부 통과
#   1 : 하나 이상 실패
#   2 : 준비 실패 (사용 오류, 저장소 루트를 찾지 못함, build.sh 실패)

# 값이 정해지지 않은 변수를 쓰면 멈춘다 (변수 이름 오타를 일찍 잡는다)
set -u

# 돌릴 시험 목록. 새 시험을 더할 때는 이 배열 한 곳만 고친다
#   src/<이름> 은 src 에서 실행하는 C 시험 바이너리 (순서는 build.sh 끝 안내 줄과 같다)
#   tools/<이름>.sh 는 저장소 루트에서 bash 로 실행하는 셸 시험
TESTS=(
    src/test_dispatcher
    src/test_verdict_handler
    src/test_write_exec_boundary
    src/test_loader_lock
    src/test_kill
    src/test_kill_session
    src/test_loader_args
    src/test_exec_path
    src/test_exec_identity
    src/test_dummy_detectors
    tools/test_judge.sh
    tools/test_report.sh
    tools/test_leak_check.sh
    tools/test_live_latency.sh
    tools/test_run_container.sh
    tools/test_runner.sh
)

# 사용법을 표준 오류에 내고 사용 오류(2)로 끝낸다
usage() {
    # 사용법 한 줄
    echo "사용법: tools/run_unit_tests.sh [--skip-build]" >&2
    # 사용 오류
    exit 2
}

# ---------- 인자 읽기 (leak_check.sh 의 while/case 방식) ----------
# build.sh 를 건너뛸지 (1 이면 건너뜀)
SKIP_BUILD=0
# 인자가 남아 있는 동안 하나씩 본다
while [[ $# -gt 0 ]]; do
    # 지금 인자의 종류로 나눈다
    case "$1" in
        # 빌드 건너뛰기
        --skip-build) SKIP_BUILD=1; shift ;;
        # 도움말도 사용법으로 끝낸다
        -h|--help) usage ;;
        # 그 밖의 인자는 사용 오류
        *) usage ;;
    esac
done

# ---------- 저장소 루트로 간다 ----------
# 이 스크립트가 있는 폴더(tools)의 한 단계 위가 저장소 루트다
ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
# 루트를 구하지 못했거나 src/build.sh 가 없으면 준비 실패
if [[ -z "$ROOT" || ! -f "$ROOT/src/build.sh" ]]; then
    # 무엇을 찾지 못했는지 알린다
    echo "[run_unit_tests] 저장소 루트를 찾지 못함 (src/build.sh 가 없음): ${ROOT:-?}" >&2
    # 준비 실패
    exit 2
fi
# 루트로 이동한다 (실패하면 준비 실패)
cd "$ROOT" || exit 2

# ---------- 빌드 ----------
# --skip-build 가 없으면 먼저 빌드한다
if ((SKIP_BUILD == 0)); then
    # 빌드 단계 제목
    echo "== 빌드 (cd src && ./build.sh) =="
    # 빌드 출력은 그대로 보인다. 실패하면 준비 실패로 끝낸다
    if ! (cd src && ./build.sh); then
        # 빌드가 실패했다는 사실
        echo "[run_unit_tests] build.sh 가 실패했다. 시험을 돌리지 않는다" >&2
        # 준비 실패
        exit 2
    fi
fi

# ---------- 시험 실행 ----------
# 요약 줄들 (시험마다 한 줄)
SUMMARY=()
# 실패한 시험 수
failures=0
# 목록의 시험을 차례로 돈다
for t in "${TESTS[@]}"; do
    # 요약에 쓸 이름 (경로와 .sh 를 뗀다)
    name="$(basename "$t" .sh)"
    # 시험 제목
    echo "== $name =="
    # 종류에 따라 실행한다. 출력은 변수에 받아 PASS 를 세고 실패하면 보여 준다
    if [[ "$t" == src/* ]]; then
        # C 시험: 바이너리가 없으면 실행하지 못한 것으로 센다 (127 은 셸이 "명령 없음" 에 쓰는 값)
        if [[ -x "$t" ]]; then
            # src 에서 실행한다 (build.sh 끝 안내 줄처럼 ./이름 으로)
            out="$(cd src && "./$name" 2>&1)"
            # 바로 종료 코드를 저장한다
            rc=$?
        else
            # 없다는 사실을 출력으로 남긴다
            out="[run_unit_tests] 바이너리가 없거나 실행할 수 없음: $t (빌드가 필요하다)"
            # 실행하지 못함
            rc=127
        fi
    else
        # 셸 시험: 저장소 루트에서 bash 로 실행한다
        out="$(bash "$t" 2>&1)"
        # 바로 종료 코드를 저장한다
        rc=$?
    fi
    # PASS 줄 수 (시험마다 PASS 줄 모양이 조금 달라 앞 공백과 뒤의 공백·콜론을 허용한다)
    passes="$(grep -cE '^ *PASS[ :]' <<<"$out")"
    # 마지막 줄 (ALL PASSED 같은 결과 줄)
    last="$(tail -n 1 <<<"$out")"
    # 종료 코드 0 이면 통과, 아니면 실패로 센다
    if [[ "$rc" -eq 0 ]]; then
        # 통과 요약 줄
        SUMMARY+=("- $name: 통과 (PASS $passes, rc=$rc)")
        # 결과 줄만 보인다
        echo "  $last"
    else
        # 실패 요약 줄
        SUMMARY+=("- $name: 실패 (PASS $passes, rc=$rc)")
        # 실패 수를 늘린다
        failures=$((failures + 1))
        # 실패한 시험의 출력을 들여써서 모두 보인다
        sed 's/^/    /' <<<"$out"
    fi
done

# ---------- 요약 ----------
# 빈 줄로 구분한다
echo
# 요약 제목
echo "== 요약 (${#TESTS[@]}개) =="
# 시험마다 한 줄
printf '%s\n' "${SUMMARY[@]}"
# 빈 줄로 구분한다
echo
# 실패가 없으면 0
if ((failures == 0)); then
    # 통과
    echo "ALL PASSED (실패 0)"
    # 종료 코드 0
    exit 0
fi
# 실패 수와 함께
echo "FAILED (실패 $failures)"
# 종료 코드 1
exit 1
