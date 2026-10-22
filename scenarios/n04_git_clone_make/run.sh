# n04_git_clone_make: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 정상 작업(오탐 측정용): 로컬 git 저장소를 만들어 커밋하고, 로컬 경로로 clone 한 뒤 make 로 빌드해서 실행한다.
# git 의 내부 실행 파일들과 make 가 부르는 gcc 가 SUSPECT 를 내는지, 세션이 만든 ./hello 실행이 SUSPECT 하나로 끝나는지 본다.
# 로컬 clone 이라 네트워크는 쓰지 않는다. gcc, make, git 이 필요하므로 rootfs 파일에 dev 를 적어 개발 rootfs 로 돈다.
# 더미 차단 탐지기(dummy_block)가 s99 에서 쓰는 예약된 파일 이름은 쓰지 않는다 (그 이름을 실행하면 BLOCK 을 낸다). 작업은 /tmp 안에서만 한다.
# git 의 소유자 검사(safe.directory)를 미리 풀지 않는다. 첫 실행에서 그 거부가 실제로 나는지 보려는 것이다.
# 실제 위험한 동작은 없다. 한 줄을 출력하는 프로그램을 로컬 저장소에서 받아 빌드하고 실행할 뿐이다.
#
# 명령을 PATH 에서 찾을 위치를 정하고, git 과 gcc 가 쓰는 HOME 을 쓰기 가능한 /tmp 로 둔다
export PATH=/usr/bin:/bin HOME=/tmp
# 명령 하나라도 실패하면 바로 그 종료 코드로 끝낸다 (git 거부나 빌드 실패가 runtime.json 의 exit_code 0 검사에 걸리게 한다)
set -e
# 원본 저장소 폴더를 만든다
mkdir /tmp/n04_src
# 원본 저장소 안으로 이동한다
cd /tmp/n04_src
# 빈 git 저장소를 만든다 (-q: 안내 출력 없이)
git init -q
# printf 한 줄짜리 C 소스를 쓴다 (따옴표 친 EOF 라 안의 글자를 셸이 해석하지 않는다)
cat > hello.c <<'CSRC'
#include <stdio.h>
int main(void) { printf("hello\n"); return 0; }
CSRC
# Makefile 을 쓴다. 레시피 줄은 탭으로 시작해야 하므로 heredoc 대신 printf 의 \t 로 넣는다
printf 'hello: hello.c\n\tgcc -o hello hello.c\n' > Makefile
# 두 파일을 커밋 대상에 올린다
git add hello.c Makefile
# 커밋한다. 사용자 정보는 -c 옵션으로만 준다 (설정 파일을 만들지 않는다)
git -c user.name=n04 -c user.email=n04@example.invalid commit -q -m 'n04: hello'
# 원본 밖으로 나온다
cd /tmp
# 로컬 경로로 clone 한다 (네트워크 없음)
git clone -q /tmp/n04_src /tmp/n04_work
# clone 한 작업 폴더로 이동한다
cd /tmp/n04_work
# make 로 빌드한다 (make 가 gcc 를 부르고 gcc 가 cc1, as, collect2, ld 를 차례로 실행한다)
make
# 방금 같은 세션이 빌드한 파일을 실행한다 (write_exec_boundary 의 SUSPECT 대상)
./hello
# 정상 종료한다 (./hello 가 마지막 명령이 되지 않게 하는 역할도 한다. s99/run.sh 의 "; true" 주석 참고)
exit 0
