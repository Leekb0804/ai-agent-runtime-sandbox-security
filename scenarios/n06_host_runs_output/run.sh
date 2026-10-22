# n06_host_runs_output: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 정상 작업(알려진 오탐 기록용): 같은 세션에서 C 파일을 쓰고 gcc 로 컴파일만 한다. 빌드한 파일은 컨테이너 안에서 실행하지 않는다.
# 같은 파일을 세션이 끝난 뒤 호스트(세션 밖)에서 직접 실행하는 것은 host.sh 가 한다 (s01 과 같은 구조, 다른 점은 컨테이너가 하는 일이 컴파일이라는 것).
# 컨테이너 안에서 실행하지 않는 이유: 같은 세션 실행의 SUSPECT 가 섞이지 않게 하려는 것이다.
# gcc 가 필요하므로 rootfs 파일에 dev 를 적어 개발 rootfs(tools/make_dev_rootfs.sh 로 만든 것)로 돈다.
# 더미 차단 탐지기(dummy_block)가 s99 에서 쓰는 예약된 파일 이름은 쓰지 않는다 (그 이름을 실행하면 BLOCK 을 낸다). 작업은 /tmp 안에서만 한다.
# 실제 위험한 동작은 없다. 한 줄을 출력하는 프로그램을 빌드할 뿐이다.
#
# 명령을 PATH 에서 찾을 위치를 정하고, gcc 가 쓰는 HOME 을 쓰기 가능한 /tmp 로 둔다
export PATH=/usr/bin:/bin HOME=/tmp
# 명령 하나라도 실패하면 바로 그 종료 코드로 끝낸다 (컴파일 실패가 runtime.json 의 exit_code 0 검사에 걸리게 한다)
set -e
# 작업 폴더로 이동한다 (이후 파일은 모두 /tmp 안에 생긴다)
cd /tmp
# printf 한 줄짜리 C 소스를 쓴다 (따옴표 친 EOF 라 안의 글자를 셸이 해석하지 않는다)
cat > hello.c <<'CSRC'
#include <stdio.h>
int main(void) { printf("hello\n"); return 0; }
CSRC
# 컴파일한다. 결과물은 /tmp/hello 이고 호스트에서는 $MYC_UPPER/tmp/hello 로 보인다 (gcc 가 cc1, as, collect2, ld 를 차례로 실행한다)
gcc -o hello hello.c
# 정상 종료한다 (빌드한 파일은 실행하지 않는다)
exit 0
