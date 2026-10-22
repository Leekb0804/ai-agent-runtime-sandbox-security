# n03_pip_install_local: 컨테이너 안에서 실행할 스크립트 (러너가 /bin/sh -c 로 실행한다)
#
# 정상 작업(오탐 측정용): 같은 세션에서 venv 를 만들고, 로컬 패키지를 pip 으로 설치한 뒤, 설치된 콘솔 스크립트를 실행한다.
# venv 가 쓴 bin/pip 과 pip 이 쓴 bin/n03tool 의 실행이 write_exec_boundary 의 SUSPECT 를 몇 번 내는지 본다.
# 네트워크는 쓰지 않는다. 컨테이너 안은 DNS 가 닿지 않아 pip 이 인덱스(PyPI)에 접속하려 하면 오래 막히므로 아래 옵션으로 접속을 막는다.
# python3, python3-venv, pip, setuptools 가 필요하므로 rootfs 파일에 dev 를 적어 개발 rootfs 로 돈다.
# 시스템 파이썬에 직접 설치하면 EXTERNALLY-MANAGED 로 거부되므로 venv 에 설치한다.
# 더미 차단 탐지기(dummy_block)가 s99 에서 쓰는 예약된 파일 이름은 쓰지 않는다 (그 이름을 실행하면 BLOCK 을 낸다). 작업은 /tmp 안에서만 한다.
# 실제 위험한 동작은 없다. 한 줄을 출력하는 로컬 패키지를 venv 에 설치해 실행할 뿐이다.
#
# 명령을 PATH 에서 찾을 위치를 정하고, python 과 pip 이 쓰는 HOME 을 쓰기 가능한 /tmp 로 둔다
export PATH=/usr/bin:/bin HOME=/tmp
# 명령 하나라도 실패하면 바로 그 종료 코드로 끝낸다 (설치 실패가 runtime.json 의 exit_code 0 검사에 걸리게 한다)
set -e
# 작업 폴더로 이동한다 (이후 파일은 모두 /tmp 안에 생긴다)
cd /tmp
# 로컬 패키지의 소스 폴더와 그 안의 모듈 폴더를 만든다
mkdir -p /tmp/n03pkg/n03pkg
# 패키지 설정을 쓴다. 빌드는 시스템 setuptools 로 하고, n03tool 이라는 콘솔 스크립트가 n03pkg 의 main 을 부르게 한다 (따옴표 친 EOF 라 안의 글자를 셸이 해석하지 않는다)
cat > /tmp/n03pkg/pyproject.toml <<'TOML'
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"

[project]
name = "n03pkg"
version = "0.1"

[project.scripts]
n03tool = "n03pkg:main"
TOML
# 모듈을 쓴다. main 은 한 줄을 출력한다 (따옴표 친 EOF 라 안의 글자를 셸이 해석하지 않는다)
cat > /tmp/n03pkg/n03pkg/__init__.py <<'PY'
def main():
    print("n03tool ok")
PY
# venv 를 만든다. --system-site-packages 는 시스템에 설치된 setuptools 를 venv 안에서 쓸 수 있게 하려는 것이다
python3 -m venv --system-site-packages /tmp/n03venv
# 로컬 패키지를 venv 에 설치한다. 옵션은 모두 네트워크 접속을 막으려는 것이다:
#   --no-index                   : 인덱스(PyPI)를 찾지 않는다
#   --no-build-isolation         : 빌드용 격리 환경을 만들지 않는다 (격리 환경은 setuptools 를 인덱스에서 받으려 한다. 대신 시스템 setuptools 를 쓴다)
#   --no-cache-dir               : 캐시를 쓰지 않는다 (HOME 아래에 캐시를 남기지 않는다)
#   --disable-pip-version-check  : pip 새 버전 확인 접속을 하지 않는다
/tmp/n03venv/bin/pip install --no-index --no-build-isolation --no-cache-dir --disable-pip-version-check /tmp/n03pkg
# pip 이 venv 에 만든 콘솔 스크립트를 직접 실행한다 (write_exec_boundary 의 SUSPECT 대상)
/tmp/n03venv/bin/n03tool
# 정상 종료한다 (n03tool 이 마지막 명령이 되지 않게 하는 역할도 한다. s99/run.sh 의 "; true" 주석 참고)
exit 0
