# s05_kill_term_ignoring_tree: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# kill switch(cgroup.kill)가 SIGTERM 을 무시하는 프로세스와 그 자식(손자)까지 종료하는지 확인한다 (일정표 중간 점검 2번의 근거).
# TERM 을 무시하는 자식 셋을 띄우고 그중 하나에 손자를 둔 뒤, /tmp/trigger 로 dummy_block 의 BLOCK 을 내 로더가 이 세션을 종료하게 한다.
# 무엇을 증명하는가: runtime.json 의 cgroup_gone 이 곧 자식 셋과 손자까지 모두 사라졌다는 증거이다.
#   run_container.sh 는 세션 cgroup 을 rmdir 하는데, 프로세스가 하나라도 남은 cgroup 은 지울 수 없다 (EBUSY).
#   exit_code 137 은 cgroup 안의 mycontainer_run 이 SIGKILL 로 죽었다는 뜻이다.
# 대조가 왜 필요한가: 자식들이 정말 TERM 을 무시했는지 확인하지 않으면, 평범한 프로세스를 죽인 것과 구별할 수 없다.
#   그래서 BLOCK 전에 자식마다 TERM 을 직접 보내 보고, 1초 뒤에도 살아 있는 자식의 pid 를 /tmp/term_ignored_ok 에 적는다.
#   host.sh 가 agent-run 이 끝난 뒤 upper 에서 /tmp/kids 와 /tmp/term_ignored_ok 가 각각 3줄인지 본다 (아니면 FAIL).
# 손자의 pid 는 적지 않는다: 손자는 대조(TERM 보내기)의 대상이 아니고, cgroup_gone 으로만 사라졌음을 확인한다.
# trap '' TERM 으로 정한 "무시"는 exec 뒤에도 유지되고 자식(손자)에게도 물려진다.
# 분수 sleep 은 busybox 에서 안 될 수 있어 1초 단위만 쓴다.
# 파일을 먼저 비우는 이유: 컨테이너 폴더는 지워지지 않아서 PID 재사용 때 이전 실행의 기록이 upper 에 남아 있을 수 있다.
# dummy_block 에 의존한다 (s03 과 같은 이름 /tmp/trigger). kill 이 실패하면 마지막 sleep 30 이 끝나 정상 종료(rc 0)하고 runtime.json 의 exit_code 137 검사가 FAIL 시킨다.
# 실제 위험한 동작은 없다. sleep 하는 프로세스를 띄우고, 내용이 비어 있는 스크립트를 만들어 실행할 뿐이다.
# 기록 파일 두 개를 비운다
: > /tmp/kids; : > /tmp/term_ignored_ok
# 자식 1: TERM 을 무시하고 자기 pid 를 적은 뒤 sleep 으로 바뀐다
sh -c 'trap "" TERM; echo $$ >> /tmp/kids; exec sleep 30' &
# 자식 2: 같은 일을 하되 exec 전에 손자 sleep 을 하나 띄운다 (손자도 TERM 무시를 물려받는다)
sh -c 'trap "" TERM; sleep 30 & echo $$ >> /tmp/kids; exec sleep 30' &
# 자식 3: 자식 1 과 같다
sh -c 'trap "" TERM; echo $$ >> /tmp/kids; exec sleep 30' &
# 세 자식이 pid 를 적을 시간을 준다
sleep 1
# 대조 1: 적힌 자식마다 TERM 을 보낸다
for p in $(cat /tmp/kids); do kill -TERM "$p"; done
# TERM 이 처리될 시간을 준다
sleep 1
# 대조 2: 그래도 살아 있는 자식의 pid 를 한 줄씩 적는다 (셋 다 살아 있어야 한다)
for p in $(cat /tmp/kids); do kill -0 "$p" 2>/dev/null && echo "$p" >> /tmp/term_ignored_ok; done
# BLOCK 을 낸다 (s03 과 같다). 로더가 cgroup.kill 로 이 세션 전체를 종료할 때까지 sleep 30 으로 살려 둔다
echo "#!/bin/sh" > /tmp/trigger; chmod +x /tmp/trigger; /tmp/trigger; sleep 30
