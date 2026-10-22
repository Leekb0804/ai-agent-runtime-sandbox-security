# n06_host_runs_output: 호스트(세션 밖)에서 실행하는 스텝. 러너가 컨테이너가 끝난 뒤 /bin/bash 로 실행한다.
#
# MYC_UPPER 는 그 컨테이너의 upperdir 이다 (컨테이너 안의 /tmp/hello 는 호스트에서 $MYC_UPPER/tmp/hello).
# 컨테이너가 빌드한 파일을 "직접" 실행한다. sh 에 인자로 넘기지 않는다 (s01 과 같은 방식).
# ${변수:?메시지} 는 변수가 비어 있으면 메시지를 내고 스크립트를 실패로 끝낸다 (엉뚱한 /tmp/hello 를 실행하지 않게 한다).
# 한 줄을 출력하는 정상 프로그램이라 위험한 동작은 없다.
# 컨테이너가 빌드한 hello 를 호스트에서 직접 실행한다
"${MYC_UPPER:?MYC_UPPER 가 비어 있다}/tmp/hello"
