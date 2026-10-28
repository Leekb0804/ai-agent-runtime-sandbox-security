# s08_symlink_disguise: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 공격 흉내: 세션이 쓴 실행 파일을 시스템 도구 이름의 심볼릭 링크로 위장해서 실행한다 (docs/exec-identity-scenarios-w4.md).
# /usr/bin/true 를 /tmp/payload 로 복사하고, /tmp/bin/ls 라는 링크를 걸어 그 링크 경로로 실행한다.
# 요청 이름의 basename(ls)과 실제 파일 이름(payload)이 다르고 실제 파일이 /tmp 바로 아래라서 exec_identity 의 규칙 L 이 잡는다.
# 실제 파일은 세션이 쓴 파일이라 쓰기 태그(TAG_HIT)도 생겨 write_exec_boundary 도 같은 실행을 잡는다 (두 탐지기가 겹치는 경우).
# 개발 rootfs 의 true 는 이름으로 동작을 고르는 멀티콜 바이너리라서 링크 이름에 따라 오류를 낼 수 있지만 exec 자체는 일어난다.
# 개발 rootfs 로 돈다 (rootfs 파일에 dev). s06, s07 과 같은 rootfs 를 쓴다.
# 실제 위험한 동작은 없다. 복사한 true 를 실행할 뿐이다.
#
# 명령을 PATH 에서 찾을 위치를 정하고, HOME 을 쓰기 가능한 /tmp 로 둔다
export PATH=/usr/bin:/bin HOME=/tmp
# 작업 폴더로 이동한다
cd /tmp
# 링크를 둘 폴더를 만들고, true 를 /tmp/payload 로 복사하고(세션의 쓰기), ls 로 보이는 링크를 걸어 그 경로로 실행한다
mkdir /tmp/bin; cp /usr/bin/true /tmp/payload; ln -s /tmp/payload /tmp/bin/ls; /tmp/bin/ls
# 정상 종료한다 (링크 실행 줄이 마지막 명령이 되지 않게 하고, 멀티콜 바이너리의 오류 종료 코드를 덮는다. s99/run.sh 의 "; true" 주석 참고)
exit 0
