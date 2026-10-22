# n05_script_exec: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 정상 작업(오탐 측정용): 같은 세션에서 셸 스크립트 파일을 쓰고 chmod +x 한 뒤 직접 실행한다.
# 세션이 쓴 스크립트를 한 번 직접 실행하므로 write_exec_boundary 의 SUSPECT 가 한 번만 나오는지 본다.
# 스크립트를 sh 에 인자로 넘기지 않고 직접 실행한다 (인터프리터에 넘기면 실행되는 파일이 sh 라 TAG_HIT 이 생기지 않는다).
# /dev/null 회귀: 스크립트와 이 파일이 > /dev/null 로 출력을 버린다. 컨테이너 안 /dev/null(mycontainer_run 4.7단계의 bind mount)이
# 안 열리면 set -e 로 바로 실패하고 runtime.json 의 exit_code 0 검사가 FAIL 을 낸다.
# 개발 rootfs 로 돈다 (rootfs 파일에 dev). 다른 n 시나리오와 같은 rootfs 를 쓰려는 것이다.
# 더미 차단 탐지기(dummy_block)가 s99 에서 쓰는 예약된 파일 이름은 쓰지 않는다 (그 이름을 실행하면 BLOCK 을 낸다). 작업은 /tmp 안에서만 한다.
# 실제 위험한 동작은 없다. 출력을 버리고 한 줄을 찍는 스크립트를 만들어 실행할 뿐이다.
#
# 명령을 PATH 에서 찾을 위치를 정하고, HOME 을 쓰기 가능한 /tmp 로 둔다
export PATH=/usr/bin:/bin HOME=/tmp
# 명령 하나라도 실패하면 바로 그 종료 코드로 끝낸다 (/dev/null 이 안 열리는 것도 여기서 걸린다)
set -e
# 작업 폴더로 이동한다 (이후 파일은 모두 /tmp 안에 생긴다)
cd /tmp
# 작은 셸 스크립트를 쓴다 (따옴표 친 EOF 라 안의 글자를 셸이 해석하지 않는다. 내용: 출력 두 번 버리고 done 출력)
cat > n05_task.sh <<'TASK'
#!/bin/sh
echo work > /dev/null
ls /tmp > /dev/null 2>&1
echo done
TASK
# 실행 권한을 준다
chmod +x n05_task.sh
# 방금 같은 세션이 쓴 스크립트를 직접 실행한다 (write_exec_boundary 의 SUSPECT 대상)
./n05_task.sh
# 이 파일 자신도 /dev/null 로 리다이렉트한다 (스크립트를 실행한 뒤에도 /dev/null 이 열리는지)
echo ok > /dev/null
# 정상 종료한다 (./n05_task.sh 가 마지막 명령이 되지 않게 하는 역할도 한다. s99/run.sh 의 "; true" 주석 참고)
exit 0
