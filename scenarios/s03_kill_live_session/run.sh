# s03_kill_live_session: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 살아 있는 세션을 cgroup.kill 로 실제로 종료하는지 확인한다.
# /tmp/trigger 를 실행하면 dummy_block 이 BLOCK 을 내고, 로더가 이 세션의 cgroup 을 종료한다.
# 그 뒤의 sleep 30 은 종료되기 전까지 세션을 살려 두는 역할이다 (종료되면 agent-run 은 137 로 끝난다).
#
# dummy_block 에 의존한다. 지금은 로더가 탐지기를 모두 켜지만,
# 탐지기 선택 옵션이 생기면 러너가 이 시나리오에서 dummy_block 을 켜야 한다.
# kill 이 실패하면 sleep 30 이 끝나 정상 종료(rc 0)한다. 판정(expect.json)이 놓치더라도
# runtime.json 의 exit_code 137 검사가 FAIL 시킨다.
# /dev/null 리다이렉트가 없는 것은 컨테이너 안에서 /dev/null 이 열리지 않던 때(mycontainer_run 의 4.7단계 bind mount 이전)의 우회이다. 지금은 열리지만 스크립트는 바꾸지 않았다.
# 실제 위험한 동작은 없다. 내용이 비어 있는 스크립트를 만들어 실행할 뿐이다.
echo "#!/bin/sh" > /tmp/trigger; chmod +x /tmp/trigger; /tmp/trigger; sleep 30
