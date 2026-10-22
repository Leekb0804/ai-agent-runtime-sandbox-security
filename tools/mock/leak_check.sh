#!/bin/bash
#
# tools/mock/leak_check.sh  -  가짜 누수 점검기 (러너의 --repeat 흐름을 테스트하려는 용도)
#
# 진짜 tools/leak_check.sh 와 같은 하위 명령(snapshot, compare)을 받지만 자원을 세지 않는다.
#   MOCK_LEAK_RECORD=<파일>   : 불릴 때마다 "하위명령 라벨 라운드 세션" (compare 는 "compare") 한 줄과
#                               snapshot 이면 로더 pid 가 있었는지("loader=있음|없음")를 그 파일에 덧붙인다
#   MOCK_LEAK_COMPARE_RC=N    : compare 의 종료 코드 (기본 0)
#   MOCK_LEAK_SNAPSHOT_RC=N   : snapshot 의 종료 코드 (기본 0)

# 하위 명령
sub="${1:-}"
# 기록 파일이 있으면 받은 인자를 적는다
if [[ -n "${MOCK_LEAK_RECORD:-}" ]]; then
    case "$sub" in
        # snapshot 은 저장 폴더를 빼고 라벨, 라운드, 세션과 로더 pid 유무를 적는다
        snapshot) echo "snapshot $3 $4 $5 loader=$([[ -n "${MYC_LEAK_LOADER_PID:-}" ]] && echo 있음 || echo 없음)" >>"$MOCK_LEAK_RECORD" ;;
        # compare 는 이름만 적는다
        compare) echo "compare" >>"$MOCK_LEAK_RECORD" ;;
    esac
fi
# 하위 명령에 따라 정해진 종료 코드로 끝낸다
case "$sub" in
    # 스냅샷
    snapshot) exit "${MOCK_LEAK_SNAPSHOT_RC:-0}" ;;
    # 비교 (표 대신 한 줄)
    compare) echo "[mock leak_check] compare rc=${MOCK_LEAK_COMPARE_RC:-0}"; exit "${MOCK_LEAK_COMPARE_RC:-0}" ;;
    # 그 밖은 사용 오류
    *) exit 2 ;;
esac
