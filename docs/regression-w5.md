# 회귀 실행 기록 (w5d3, --repeat 10)

w5d3 에 VM 에서 시나리오를 10번 반복 실행한 결과를 옮긴 것이다. 출처는 러너 출력을 저장한 VM 의 `~/w5d3_repeat10.txt` (2576줄)와 세션 meta.json 집계다.

- [실측]: 출력 파일이나 VM 에서 실행한 명령의 결과를 그대로 옮긴 값
- [추정]: 단위나 의미가 출력에 적혀 있지 않아 짐작한 것
- [확인 못함]: 근거를 찾지 못한 것

## 실행 조건

- 명령: `sudo ./run_scenarios.sh --repeat 10 --leak-interval 1` 을 bash 의 `( time … )` 로 감싸 출력을 `~/w5d3_repeat10.txt` 에 저장했다 [실측: 실행한 사람의 터미널 기록. 출력 파일에는 명령줄이 없다].
- 시나리오 수와 반복 횟수: 시나리오 15개 x 10회 = 세션 150개 [실측]. 출력의 `[PASS]` 줄을 시나리오 이름으로 세면 15개 이름이 각각 10번 나온다.
  - n01_compile_run, n03_pip_install_local, n04_git_clone_make, n05_script_exec, n06_host_runs_output
  - s00_benign, s01_write_exec_cross, s02_write_exec_same_session, s03_kill_live_session, s04_write_exec_live
  - s05_kill_term_ignoring_tree, s06_memfd_exec_path, s07_memfd_exec_fd, s08_symlink_disguise, s99_dummy_block
- 세션 루트: `/tmp/myc_scen.tpTxst/sessions` [실측]
- 소요 시간: 298.039 초 [실측: 터미널의 TIMEFORMAT 이 %3R 이라 실제 경과 시간(초)이 소수점 셋째 자리까지 출력됨]

## 결과

- 시나리오: 150/150 통과 [실측] (출력: `시나리오 150/150 통과`)
- FAIL: 0 [실측]. `[FAIL]` 로 시작하는 줄이 0개이고, 출력의 마지막 판정 줄은 `결과: ALL PASSED` 이다.
- 러너의 종료 코드: rc 0 [실측: 같은 터미널 기록의 `echo rc=$?`]. 출력 파일에는 종료 코드 줄이 없다.
- `[!]` 로 시작하는 줄 0개, '시작 표시 파일 생성 실패' 0줄, '세션 시작 거부' 0줄 [실측].

### 지연 요약 (출력 그대로) [실측]

```
지연 요약 (B안, 10회)
  전체: 최소 101, 중앙값 102, 최대 104 ms (10개)
  실행→HIT: 최소 1, 중앙값 2, 최대 5 ms (10개)
  HIT→kill 요청: 최소 0, 중앙값 0, 최대 0 ms (10개)
  kill 요청→종료: 최소 97, 중앙값 100, 최대 103 ms (10개)
```

### 누수 점검 (출력 그대로) [실측]

```
[leak_check] 스냅샷 13개: 처음 start (라운드 0, 세션 0), 마지막 end (라운드 10, 세션 150)
판정 항목           기준           처음  마지막   차이  비고
PASS cgroup_dirs      0 증가              0          0        0  
PASS netns            0 증가              0          0        0  
PASS veth             0 증가              0          0        0  
PASS mounts           0 증가              0          0        0  
PASS procs            0 증가              0          0        0  
PASS zombies          0 증가              0          0        0  
PASS map_entries      0 증가              0          0        0  
PASS ipt_filter       0 증가              5          5        0  
PASS ipt_nat          0 증가              5          5        0  
PASS work_dirs        0 증가              5          5        0  
PASS unattributed     0 증가              0          0        0  
PASS container_dirs   +150               1860       2010      150  
PASS session_dirs     +150                  0        150      150  
PASS bycgroup_links   +150                  0        150      150  
INFO kill_sessions    기준값             0         40       40  meta.json exit_code 137 인 세션
PASS state_files      +40                 749        789       40  kill 세션 수와 같음
[leak_check] 로더 값: ready(r0,s0):fd=19,rss=3864 r1(r1,s15):fd=49,rss=3940 r2(r2,s30):fd=79,rss=3940 r3(r3,s45):fd=109,rss=3940 r4(r4,s60):fd=139,rss=3940 r5(r5,s75):fd=147,rss=3940 r6(r6,s90):fd=147,rss=3940 r7(r7,s105):fd=147,rss=3940 r8(r8,s120):fd=147,rss=3940 r9(r9,s135):fd=147,rss=3940 r10(r10,s150):fd=147,rss=3940 end(r10,s150):fd=147,rss=3940 
PASS loader_fd_max    <=151                19        147      128  고정분 19 + 여유 132
PASS loader_fd_late   후반 0증가        147        147       +0  
PASS loader_rss_kb    <=1024kB           3940       3940        0  후반부
INFO write_tags       기록만             -      10066        -  로더가 떠 있던 마지막 스냅샷
INFO container_bytes  기록만     317383211  431895771 114512560  바이트
[leak_check] 결과: 합격
```

### INFO 줄 (위 표의 줄 그대로) [실측]

```
INFO kill_sessions    기준값             0         40       40  meta.json exit_code 137 인 세션
INFO write_tags       기록만             -      10066        -  로더가 떠 있던 마지막 스냅샷
INFO container_bytes  기록만     317383211  431895771 114512560  바이트
```

## started 집계

- 명령 (VM):

```
sudo bash -c 'jq -r "[.started, .exit_code] | @tsv" /tmp/myc_scen.tpTxst/sessions/*/meta.json | sort | uniq -c'
```

- 결과 (개수, started, exit_code 순) [실측]:

```
    110 true    0
     40 true    137
```

- 대조 [실측 두 값의 비교]: 110 + 40 = 150 은 세션 수와 같고, exit_code 137 세션 40 은 누수 점검의 kill_sessions 40 과 같다.

## 읽는 법과 한계

- 로더 fd: 첫 스냅샷의 19 에서 r5(세션 75)의 147 까지 128 늘었고, 그 뒤 마지막 스냅샷까지 147 이다 [실측: 누수 점검의 `[leak_check] 로더 값` 줄].
  - 소스의 상한: `src/loader/session_log.c` 는 세션 칸 하나에 events.jsonl 과 verdicts.jsonl 두 파일을 열고, 칸은 밀려날 때와 로더 종료 때만 닫는다. 칸 수는 64 다. 36~41줄을 그대로 옮긴다:

```c
/*
 * 로더는 세션이 끝난 것을 알 수 없어서(session_log.h 의 session_log_close_all 설명) 칸은 밀려날 때(LRU)와
 * 로더 종료 때만 닫힌다. 그래서 로그 FD 는 최대 2 x MAX_SESSIONS 개(events, verdicts)까지 열려 있다.
 * tools/leak_check.sh 의 SESSION_SLOTS 와 같은 값이어야 한다 (누수 점검의 FD 판정이 이 값을 쓴다).
 */
#define MAX_SESSIONS 64                    /* 동시에 열어 둘 세션 수 */
```

  - 2 x 64 = 128 이고, 늘어난 양 128 과 같다. 다만 147 에서 멈춘 것이 이 상한 때문인지는 VM 에서 로더의 fd 목록으로 확인하지 않았다 [확인 못함].
  - 스냅샷별 fd 는 세션 수 x 2 + 19 와 s15~s60 에서 모두 같고(49, 79, 109, 139), s75 에서는 상한 128 에 닿아 147 이 된다 [추정: 산술 일치. 로더의 fd 목록으로는 확인하지 않았다].
- write_tags: 로더가 떠 있던 마지막 스냅샷의 값(10066)만 있고 처음 값과 차이가 `-` 라서, 실행 중에 늘었는지는 이 출력으로 알 수 없다 [실측: 표의 처음·차이 칸이 `-`]. 상한 10240 의 LRU 맵이라 무한히 늘지는 않는다 [코드확인: write_tag.h:17, 39-40]. 10066 이 10240 바로 아래인 이유는 확인하지 못했다 [확인 못함].
- kill 요청→종료 값(최소 97, 중앙값 100, 최대 103 ms)이 왜 이 크기인지는 확인하지 않았다 [확인 못함].
- 이 문서의 숫자는 VM 에서 한 번 돌린 결과다. 다른 실행에서도 같은 값이 나오는지는 확인하지 않았다.
