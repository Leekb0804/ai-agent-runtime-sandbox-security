# s02_write_exec_same_session: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 빌드 후 실행처럼 같은 세션이 파일을 쓰고 그대로 실행한다. 세션 안 실행이므로 BLOCK 이 나오면 안 된다 (SUSPECT 는 허용).
# 끝의 "; true": s99 와 같은 이유로 둔다 (마지막 명령의 execve 관측 누락이 재현되지 않았지만 원인을 모르므로 s99 와 같은 형태를 유지한다. s99/run.sh 의 주석 참고).
# 파일 이름을 /tmp/payload 로 둔 이유는 s01 과 같다. 실제 위험한 동작은 없다.
echo "#!/bin/sh" > /tmp/payload; chmod +x /tmp/payload; /tmp/payload; true
