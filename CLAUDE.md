# 규칙
- 커밋 메시지: "w1d4: 요약" 형식 (주차+일차)
- 커밋 전 git status와 diff를 보여주고, 내가 확인하기 전에는 push하지 않는다
- vmlinux.h, *.skel.h 등 생성물은 커밋하지 않는다
- sudo 명령이나 rm -rf는 실행하지 말고 명령만 제안한다
- 계획서(프로젝트 문서)의 v0.1 일정 기준으로 작업한다

# Git 작업 규칙
- 커밋 요청을 받으면 먼저 git status와 git diff를 보여주고, 커밋 메시지 초안을 제안한다
- 내가 명시적으로 OK하기 전에는 git commit을 실행하지 않는다
- 커밋 메시지는 "w1d4: 요약" 형식(주차+일차)을 따른다
- git push, git reset --hard, git clean, git rebase는 내가 직접 요청했을 때만 제안한다
- 생성물(vmlinux.h, *.skel.h, *.bpf.o, 빌드 바이너리)은 스테이징하지 않는다
- 스테이징할 때 git add -A 대신 파일을 명시해서 추가하고, 무엇을 추가했는지 보여준다
- 커밋 메시지에 Co-Authored-By 줄을 넣지 않는다


