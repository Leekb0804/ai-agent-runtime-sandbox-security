# s01_write_exec_cross: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 컨테이너(세션)가 파일을 쓰고 실행 권한만 준다. 실행은 하지 않는다.
# 같은 파일을 컨테이너 밖(호스트)에서 실행하는 것은 host.sh 가 한다 (러너가 컨테이너가 끝난 뒤 실행한다).
# 파일 이름을 /tmp/trigger 가 아닌 /tmp/payload 로 둔 이유: 더미 탐지기 dummy_block 이 /tmp/trigger 에 BLOCK 을 내서 결과가 섞이는 것을 피하려는 것이다.
# 실제 위험한 동작은 없다. 내용이 비어 있는 스크립트를 만들 뿐이다.
echo "#!/bin/sh" > /tmp/payload; chmod +x /tmp/payload
