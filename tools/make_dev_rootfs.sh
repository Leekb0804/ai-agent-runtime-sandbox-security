#!/bin/bash
#
# tools/make_dev_rootfs.sh
#
# ===== 이 파일의 역할 =====
# 정상 시나리오(n 시나리오: 컴파일 후 실행, pip install, git clone 후 빌드 등. npm install 은 보류)를 컨테이너 안에서
# 돌리기 위한 개발용 rootfs 를 debootstrap 으로 만든다. s 시나리오가 쓰는 busybox rootfs 는 건드리지 않는다.
#
# 사용법:
#   tools/make_dev_rootfs.sh --dry-run   실제로는 아무것도 하지 않고 읽은 값과 실행할 명령만 출력한다 (sudo 불필요)
#   tools/make_dev_rootfs.sh             rootfs 를 만든다. 내부에서 sudo 를 부르므로 일반 사용자로 실행한다
#
# 환경변수:
#   MYC_DEV_ROOTFS_DIR  만들 위치 (기본 /home/dev/practice/mycontainer/dev_rootfs). 이미 있으면 지우지 않고 오류로 끝난다
#   MYC_MIRROR          패키지 미러 (기본은 호스트 apt 설정 /etc/apt/sources.list.d/ubuntu.sources 의 URIs 값)
# 릴리스 이름과 아키텍처는 호스트에서 읽는다 (/etc/os-release, dpkg --print-architecture).

# -e: 명령이 실패하면 멈춘다, -u: 정해지지 않은 변수를 쓰면 멈춘다, -o pipefail: 파이프 중간 명령의 실패도 실패로 본다
set -euo pipefail

# 기본 만들 위치 (busybox rootfs 와 같은 상위 폴더)
DEFAULT_DIR="/home/dev/practice/mycontainer/dev_rootfs"
# 기본 미러. 호스트의 /etc/apt/sources.list.d/ubuntu.sources 에 적힌 URIs 값이다 (이 호스트는 arm64 도 이 주소에서 받는다)
DEFAULT_MIRROR="http://kr.archive.ubuntu.com/ubuntu/"
# debootstrap 으로 함께 설치할 패키지 (쉼표로 구분, debootstrap 의 --include 형식)
# python3-setuptools, python3-wheel: 외부 접속 없이 로컬 패키지를 pip install 할 때 빌드 도구를 인터넷에서 받지 않게 한다
# ca-certificates: 나중에 HTTPS 접속(git clone, 패키지 레지스트리)을 시험할 때 필요하다
# nodejs, npm 은 넣지 않는다: 이 릴리스의 npm 은 아카이브에 없는 node-* 패키지에 의존해 설치할 수 없다 (w3d2 확인).
# npm install 시나리오(n02)는 보류하고, 필요해지면 공식 Node.js 배포본을 별도로 넣는다
PACKAGES="gcc,libc6-dev,make,python3,python3-pip,python3-venv,python3-setuptools,python3-wheel,git,ca-certificates"
# 사용할 컴포넌트 (python3-pip, python3-venv, python3-wheel 은 universe 에 있고 나머지는 main 에 있다)
COMPONENTS="main,universe"

# 만들 위치: 환경변수가 있으면 그 값, 없으면 기본값
DIR="${MYC_DEV_ROOTFS_DIR:-$DEFAULT_DIR}"
# 미러: 환경변수가 있으면 그 값, 없으면 기본값
MIRROR="${MYC_MIRROR:-$DEFAULT_MIRROR}"
# 만들 위치는 절대 경로여야 한다. debootstrap 은 /tmp 로 이동한 뒤 실행하므로 상대 경로면 다른 곳에 만들어진다
if [[ "$DIR" != /* ]]; then
    # 이유를 알리고 시작하지 않는다
    echo "[make_dev_rootfs] MYC_DEV_ROOTFS_DIR 는 절대 경로여야 한다: $DIR" >&2
    # 인자 오류로 끝낸다
    exit 2
fi

# 인자 처리: --dry-run 하나만 받는다
DRY_RUN=0
# 받은 인자를 하나씩 본다
for arg in "$@"; do
    # 인자에 따라 나눈다
    case "$arg" in
        # 실행하지 않고 출력만 한다
        --dry-run) DRY_RUN=1 ;;
        # 그 밖의 인자는 거부한다
        *) echo "[make_dev_rootfs] 알 수 없는 인자: $arg (사용법: tools/make_dev_rootfs.sh [--dry-run])" >&2; exit 2 ;;
    esac
done

# 호스트 릴리스 이름 (예: resolute). /etc/os-release 의 VERSION_CODENAME 줄에서 값만 꺼내고 따옴표를 지운다
CODENAME="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
# 호스트 아키텍처 (예: arm64)
ARCH="$(dpkg --print-architecture)"
# 둘 중 하나라도 비었으면 debootstrap 에 넘길 수 없으므로 멈춘다
if [[ -z "$CODENAME" || -z "$ARCH" ]]; then
    # 무엇을 못 읽었는지 알린다
    echo "[make_dev_rootfs] 릴리스 이름 또는 아키텍처를 읽지 못함 (CODENAME='$CODENAME', ARCH='$ARCH')" >&2
    # 오류로 끝낸다
    exit 1
fi

# 실행할 debootstrap 명령 (배열로 두어 공백이 있어도 인자가 갈라지지 않게 한다)
CMD=(sudo debootstrap --variant=minbase "--components=$COMPONENTS" "--arch=$ARCH" "--include=$PACKAGES" "$CODENAME" "$DIR" "$MIRROR")

# 읽은 값을 보여 준다
echo "[make_dev_rootfs] 릴리스: $CODENAME"
# 아키텍처
echo "[make_dev_rootfs] 아키텍처: $ARCH"
# 미러
echo "[make_dev_rootfs] 미러: $MIRROR"
# 만들 위치
echo "[make_dev_rootfs] 대상: $DIR"
# 실행할 명령. printf '%q ' 는 각 인자를 셸에 그대로 붙여 넣을 수 있는 형태로 출력한다
echo "[make_dev_rootfs] 명령: $(printf '%q ' "${CMD[@]}")"

# --dry-run 이면 여기서 끝낸다. 참고로 대상과 debootstrap 상태만 알려 준다 (실패로 보지 않는다)
if [[ $DRY_RUN -eq 1 ]]; then
    # 대상이 이미 있으면 실제 실행은 거부된다는 것을 알린다 (-e 있음, -L 링크)
    if [[ -e "$DIR" || -L "$DIR" ]]; then
        # 실제 실행 때의 동작을 미리 알린다
        echo "[make_dev_rootfs] (참고) 대상이 이미 있음. 실제 실행은 지우지 않고 오류로 끝난다"
    fi
    # debootstrap 이 없으면 실제 실행은 안내 후 끝난다는 것을 알린다
    if ! command -v debootstrap >/dev/null 2>&1; then
        # 설치 방법을 함께 알린다
        echo "[make_dev_rootfs] (참고) debootstrap 이 없음: sudo apt install -y debootstrap"
    fi
    # 아무것도 하지 않았음을 알린다
    echo "[make_dev_rootfs] --dry-run: 아무것도 실행하지 않았다"
    # 성공으로 끝낸다
    exit 0
fi

# 대상이 이미 있으면 덮어쓰거나 지우지 않고 멈춘다 (빈 폴더나 링크여도 마찬가지)
if [[ -e "$DIR" || -L "$DIR" ]]; then
    # 이유와 다른 위치를 쓰는 방법을 알린다
    echo "[make_dev_rootfs] 대상이 이미 있음: $DIR (아무것도 지우지 않는다. 직접 지우거나 MYC_DEV_ROOTFS_DIR 로 다른 위치를 지정하라)" >&2
    # 오류로 끝낸다
    exit 1
fi

# debootstrap 이 없으면 설치 방법을 알리고 멈춘다
if ! command -v debootstrap >/dev/null 2>&1; then
    # 설치 명령을 알린다
    echo "[make_dev_rootfs] debootstrap 이 없다. 먼저 설치하라: sudo apt install -y debootstrap" >&2
    # 오류로 끝낸다
    exit 1
fi

# debootstrap 을 실행한다. 실패하면 로그 위치를 알리고 멈춘다
echo "[make_dev_rootfs] debootstrap 시작 (네트워크로 패키지를 받는다)"
# if ! 명령 : 명령이 실패했을 때만 안쪽을 실행한다 (set -e 로 바로 끝나지 않게 한다)
# ( ... ) 서브셸 안에서 /tmp 로 이동한 뒤 실행한다. debootstrap 이 부르는 wget 은 현재 폴더에 root 소유 wget-log 를 남기는데,
# 저장소 최상위에서 실행하면 그 파일이 저장소에 생기기 때문이다 (wget-log, wget-log.1, wget-log.2 가 실제로 생겼다).
# 서브셸이라 이 이동은 바깥 스크립트의 현재 폴더를 바꾸지 않는다. cd 가 실패하면 && 뒤를 실행하지 않고 서브셸이 실패로 끝나 아래 안내로 간다.
# if 조건 안의 서브셸이라 set -e 로 스크립트가 바로 끝나지 않고, 서브셸의 종료 코드(= debootstrap 의 종료 코드)로 분기한다
if ! (cd /tmp && "${CMD[@]}"); then
    # 실패를 알린다
    echo "[make_dev_rootfs] debootstrap 실패" >&2
    # debootstrap 은 대상 안의 debootstrap/debootstrap.log 에 자세한 로그를 남긴다. 패키지 이름이 틀리면 여기에 나온다
    echo "[make_dev_rootfs] 로그 확인: sudo tail -n 50 $(printf '%q' "$DIR/debootstrap/debootstrap.log")" >&2
    # 어느 패키지가 문제인지 찾는 방법을 알린다
    echo "[make_dev_rootfs] 패키지 이름 문제인지 확인: sudo grep -iE \"couldn't find|unable to locate|E: \" $(printf '%q' "$DIR/debootstrap/debootstrap.log")" >&2
    # 실패한 대상 폴더는 남는다. 지우지 않는다는 것을 알린다
    echo "[make_dev_rootfs] 대상 폴더 $DIR 는 지우지 않았다. 다시 만들려면 직접 지운 뒤 실행하라" >&2
    # 오류로 끝낸다
    exit 1
fi

# ---------------- 자체 점검 (실패해도 계속 진행하고 마지막에 요약) ----------------
# 실패한 점검 이름을 모은다
FAILS=()
# 점검 결과 한 줄을 출력하고, 실패면 목록에 더한다. 사용법: report <이름> <0 이면 통과> <설명>
report() {
    # 점검 이름
    local name="$1"
    # 결과 코드 (0 이면 통과)
    local rc="$2"
    # 사람이 읽을 설명
    local detail="$3"
    # 통과와 실패를 나눠 출력한다
    if [[ "$rc" -eq 0 ]]; then
        # 통과
        echo "  PASS  $name  $detail"
    else
        # 실패
        echo "  FAIL  $name  $detail"
        # 요약에 쓰려고 모은다
        FAILS+=("$name")
    fi
}

# 점검 시작을 알린다
echo "[make_dev_rootfs] 자체 점검"

# (a) dev/null 이 문자 장치 (주 번호 1, 부 번호 3) 인가. 컨테이너가 이 노드 위에 호스트 /dev/null 을 bind mount 한다
if [[ -c "$DIR/dev/null" ]]; then
    # stat 의 %t,%T 는 주/부 번호를 16진수로 낸다 (1,3 이면 1,3)
    devnum="$(stat -c '%t,%T' "$DIR/dev/null")"
    # 1,3 이면 통과
    [[ "$devnum" == "1,3" ]] && rc=0 || rc=1
    # 결과를 남긴다
    report "dev_null" "$rc" "(문자 장치, 번호 $devnum, 기대 1,3)"
else
    # 없거나 문자 장치가 아니면 실패. 컨테이너 시작(4.7단계)이 실패하게 된다
    report "dev_null" 1 "($DIR/dev/null 이 없거나 문자 장치가 아님. 컨테이너 4.7단계가 실패한다)"
fi

# (b) 도구가 있는가. chroot 안에서 command -v 로 경로를, --version 의 첫 줄로 버전을 본다
for tool in gcc make python3 pip3 git; do
    # chroot 안의 /bin/sh 로 확인한다. 실패해도 멈추지 않게 if 안에서 실행하고 출력은 변수에 받는다
    if out="$(sudo chroot "$DIR" /bin/sh -c "command -v $tool && $tool --version 2>&1 | head -n 1" 2>&1)"; then
        # 경로와 버전을 한 줄로 이어 보여 준다
        report "tool_$tool" 0 "($(tr '\n' ' ' <<<"$out"))"
    else
        # 없거나 실행되지 않으면 실패
        report "tool_$tool" 1 "(없거나 실행 실패: $(tr '\n' ' ' <<<"$out"))"
    fi
done

# (c) setuid 파일 목록 (정보용. 통과/실패로 보지 않는다). -xdev 는 다른 파일시스템으로 넘어가지 않게 한다
echo "  INFO  setuid 파일:"
# 목록을 들여써서 보여 준다. 실패해도 멈추지 않게 || true
sudo find "$DIR" -xdev -perm -4000 -type f 2>/dev/null | sed 's/^/        /' || true

# (d) 크기 (정보용)
echo "  INFO  크기: $(sudo du -sh "$DIR" 2>/dev/null | cut -f1)"

# (e) /tmp 권한이 1777 인가 (모든 사용자가 쓸 수 있고 스티키 비트가 있음)
tmpmode="$(stat -c '%a' "$DIR/tmp" 2>/dev/null || echo "없음")"
# 1777 이면 통과
[[ "$tmpmode" == "1777" ]] && rc=0 || rc=1
# 결과를 남긴다
report "tmp_mode" "$rc" "(권한 $tmpmode, 기대 1777)"

# (f) /usr/bin/sh 또는 /bin/sh 가 있는가 (러너가 /bin/sh -c 로 시나리오를 실행한다)
if [[ -e "$DIR/usr/bin/sh" || -e "$DIR/bin/sh" ]]; then
    # 있으면 통과
    report "sh" 0 "(있음)"
else
    # 없으면 실패
    report "sh" 1 "($DIR/usr/bin/sh 와 $DIR/bin/sh 모두 없음)"
fi

# 요약
if [[ ${#FAILS[@]} -eq 0 ]]; then
    # 전부 통과
    echo "[make_dev_rootfs] 완료: $DIR (점검 모두 통과)"
else
    # 실패한 점검 이름을 보여 준다. rootfs 는 만들어졌으므로 지우지 않는다
    echo "[make_dev_rootfs] 완료: $DIR (실패한 점검: ${FAILS[*]})"
    # 점검 실패를 종료 코드로 알린다
    exit 1
fi
