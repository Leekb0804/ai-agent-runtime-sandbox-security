# s06_memfd_exec_path: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 공격 흉내: 파일시스템에 실행 파일을 쓰지 않고 메모리 파일(memfd)에 담아 실행한다 (docs/exec-identity-scenarios-w4.md).
# python3 가 memfd_create 로 메모리 파일을 만들고 /usr/bin/true 의 내용을 써 넣은 뒤, 경로 문자열 /proc/self/fd/<N> 으로 execve 한다.
# 디스크에 쓴 파일이 없으므로 쓰기 태그(TAG_HIT)가 생기지 않아 write_exec_boundary 는 보지 못하고, exec_identity 의 규칙 M 이 잡는다.
# argv[0] 을 true 로 주는 이유: 개발 rootfs 의 true 는 이름으로 동작을 고르는 멀티콜 바이너리라서다.
# 개발 rootfs 로 돈다 (rootfs 파일에 dev). busybox rootfs 에는 python3 가 없다.
# 실제 위험한 동작은 없다. 메모리에 담은 true 를 실행할 뿐이다.
#
# 명령을 PATH 에서 찾을 위치를 정하고, HOME 을 쓰기 가능한 /tmp 로 둔다
export PATH=/usr/bin:/bin HOME=/tmp
# 작업 폴더로 이동한다
cd /tmp
# memfd 를 만들고 true 의 내용을 써서 /proc/self/fd/<N> 경로로 실행한다 (execve 가 성공하면 python3 프로세스가 true 로 바뀐다)
/usr/bin/python3 -c 'import os; fd=os.memfd_create("x", 0); os.write(fd, open("/usr/bin/true","rb").read()); os.execve("/proc/self/fd/%d" % fd, ["true"], {})'
# 정상 종료한다 (python3 줄이 마지막 명령이 되지 않게 한다. s99/run.sh 의 "; true" 주석 참고)
exit 0
