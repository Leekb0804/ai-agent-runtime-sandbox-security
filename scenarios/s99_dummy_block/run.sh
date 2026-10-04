# s99_dummy_block: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 더미 탐지기(dummy_block)가 파일 이름 /tmp/trigger 의 실행을 BLOCK 으로 판정하는지 확인한다.
# 실제 위험한 동작은 하지 않는다. 내용이 비어 있는 스크립트를 만들어 실행할 뿐이다.
#
# 끝의 "; true": 이것 없이 /tmp/trigger 를 마지막 명령으로 실행하면, 컨테이너 안에서
# 그 execve 이벤트가 로그에 나타나지 않았다 (2026-10-07 s99 FAIL).
# 호스트의 busybox strace 로는 두 경우 모두 execve 가 호출된다.
# 원인은 조사 중이므로 원인이 밝혀지기 전에는 지우지 않는다.
echo "#!/bin/sh" > /tmp/trigger; chmod +x /tmp/trigger; /tmp/trigger; true
