# s05_kill_term_ignoring_tree: 호스트(세션 밖)에서 실행하는 스텝. 러너가 컨테이너가 끝난 뒤(A안) /bin/bash 로 실행한다.
#
# MYC_UPPER 는 그 컨테이너의 upperdir 이다 (컨테이너 안의 /tmp/kids 는 호스트에서 $MYC_UPPER/tmp/kids).
# 대조가 성립했는지 본다: 자식 셋이 pid 를 적었고(kids 3줄), 셋 모두 TERM 을 받고도 살아 있었다(term_ignored_ok 3줄).
# 하나라도 어긋나면 이유를 한 줄 내고 실패(1)로 끝나서 러너가 이 시나리오를 FAIL 로 본다.
# ${변수:?메시지} 는 변수가 비어 있으면 메시지를 내고 스크립트를 실패로 끝낸다 (엉뚱한 /tmp 를 보지 않게 한다).
# 컨테이너의 upper 경로 (비어 있으면 여기서 멈춘다)
u="${MYC_UPPER:?MYC_UPPER 가 비어 있다}"
# 기대하는 자식 수
want=3
# 파일 하나의 줄 수를 낸다. 파일이 없으면 "없음"
count() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 없음; fi; }
# 자식이 적은 pid 줄 수
kids="$(count "$u/tmp/kids")"
# TERM 을 받고도 살아 있던 자식 줄 수
ignored="$(count "$u/tmp/term_ignored_ok")"
# 자식 셋이 pid 를 적지 않았으면 대조를 할 수 없다
if [[ "$kids" != "$want" ]]; then echo "[s05] 자식 pid 줄 수가 $want 이 아님: $kids ($u/tmp/kids)"; exit 1; fi
# 셋 모두 TERM 을 무시하지 않았으면 이 시나리오는 "TERM 무시 프로세스도 종료"를 증명하지 못한다
if [[ "$ignored" != "$want" ]]; then echo "[s05] TERM 을 받고도 살아 있던 자식 수가 $want 이 아님: $ignored ($u/tmp/term_ignored_ok)"; exit 1; fi
# 대조가 성립했다
echo "[s05] 대조 성립: 자식 $kids 개가 pid 를 적었고 $ignored 개 모두 TERM 을 무시했다"
