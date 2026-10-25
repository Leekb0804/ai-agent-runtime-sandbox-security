# s04_write_exec_live: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 컨테이너(세션)가 파일을 쓰고 실행 권한을 준 뒤, 준비 표시(/tmp/myc_ready)를 만들고 살아 있는 채로 기다린다.
# 이 시나리오에는 live.json 이 있으므로 러너가 준비 표시를 보고 컨테이너가 살아 있는 동안 host.sh 를 실행한다 (B안).
# host.sh 가 쓴 파일을 세션 밖에서 실행하면 write_exec_boundary 가 BLOCK 을 내고, 로더가 살아 있는 이 세션을 cgroup.kill 로 종료한다.
# 준비 표시는 payload 를 다 쓰고 권한을 준 뒤에 만든다 (sh 가 순서대로 실행한다). 그래야 host.sh 가 완성된 파일을 실행한다.
# sleep 20 은 종료되기 전까지 세션을 살려 두는 역할이다. kill 이 실패하면 sleep 이 끝나 정상 종료(rc 0)하고 runtime.json 의 exit_code 137 검사가 FAIL 시킨다.
# 20초는 러너의 준비 마감(15초)과 종료 마감(30초)의 범위 안이고 AGENT_TIMEOUT_S(60초)보다 짧다.
# 파일 이름을 /tmp/trigger 가 아닌 /tmp/payload 로 둔 이유: 더미 탐지기 dummy_block 이 /tmp/trigger 에 BLOCK 을 내서 결과가 섞이는 것을 피하려는 것이다.
# 실제 위험한 동작은 없다. 내용이 비어 있는 스크립트를 만들 뿐이다.
echo "#!/bin/sh" > /tmp/payload; chmod +x /tmp/payload; touch /tmp/myc_ready; sleep 20
