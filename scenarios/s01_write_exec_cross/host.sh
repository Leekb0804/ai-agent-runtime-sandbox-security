# s01_write_exec_cross: 호스트(세션 밖)에서 실행하는 스텝. 러너가 컨테이너가 끝난 뒤 /bin/bash 로 실행한다.
#
# MYC_UPPER 는 그 컨테이너의 upperdir 이다 (컨테이너 안의 /tmp/payload 는 호스트에서 $MYC_UPPER/tmp/payload).
# 컨테이너가 쓴 파일을 "직접" 실행한다. sh 에 인자로 넘기면 exec 되는 파일이 인터프리터라 탐지되지 않는다 (수용한 한계).
# ${변수:?메시지} 는 변수가 비어 있으면 메시지를 내고 스크립트를 실패로 끝낸다 (엉뚱한 /tmp/payload 를 실행하지 않게 한다).
# 내용이 비어 있는 스크립트라 아무 일도 하지 않는다.
"${MYC_UPPER:?MYC_UPPER 가 비어 있다}/tmp/payload"
