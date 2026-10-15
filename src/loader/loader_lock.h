/*
 * loader_lock.h
 *
 * 역할: 로더(myc_loader)가 살아 있는지를 flock 잠금으로 확인하는 약속.
 *
 * 로더는 준비(후킹 연결과 ring buffer 생성)가 끝나면 잠금 파일에 배타 잠금(LOCK_EX)을 걸고
 * 프로세스가 끝날 때까지 쥔다. agent-run(mycontainer_run)은 같은 파일에 공유 잠금(LOCK_SH)을
 * 기다리지 않고(LOCK_NB) 시도한다.
 *   - 시도가 실패한다 = 누가 쥐고 있다 = 로더가 살아 있다
 *   - 시도가 성공한다 = 쥔 프로세스가 없다 = 로더가 없다
 *     (크래시나 SIGKILL 도 포함한다. 프로세스가 죽으면 열린 파일이 닫히면서 커널이 잠금을 푼다)
 *
 * 잠금 파일은 지우지 않는다. 지우고 다시 만들면 inode 가 달라져서 서로를 보지 못한다.
 * 이 헤더 하나를 로더와 mycontainer_run 이 같이 쓰고, 판정 로직은 sudo 없이 단위 테스트한다.
 */
#ifndef LOADER_LOCK_H
#define LOADER_LOCK_H

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/file.h>
#include <unistd.h>

#define MYC_LOADER_LOCK_DEFAULT "/run/myc_loader.lock"

/* 잠금 파일 경로. 테스트에서는 환경변수 MYC_LOCK_PATH 로 바꾼다. */
static inline const char *myc_loader_lock_path(void)
{
    const char *p = getenv("MYC_LOCK_PATH");
    return (p && *p) ? p : MYC_LOADER_LOCK_DEFAULT;
}

/*
 * 로더 쪽. 배타 잠금을 걸고 그 fd 를 돌려준다.
 * 반환: 잠금 fd (0 이상, 프로세스가 끝날 때까지 닫지 말 것) / 실패하면 -1 (errno 설정)
 * O_CLOEXEC: exec 로 새 프로그램이 뜰 때 이 fd 가 넘어가 잠금이 계속 쥐어지는 일을 막는다.
 */
static inline int myc_loader_lock_acquire(const char *path)
{
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0)
        return -1;

    /* agent-run 이 확인하느라 아주 잠깐 공유 잠금을 쥔 순간과 겹칠 수 있어서 짧게 재시도한다 (최대 약 100ms) */
    for (int tries = 0; tries < 10; tries++) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0)
            return fd;
        if (errno != EWOULDBLOCK)
            break;
        usleep(10 * 1000);
    }

    int saved = errno;    /* close 가 errno 를 덮어쓸 수 있어서 먼저 보관 */
    close(fd);
    errno = saved;
    return -1;
}

/*
 * agent-run 쪽. 로더가 잠금을 쥐고 있는지 확인한다.
 * 반환: 1 = 누가 쥐고 있음 (로더 있음) / 0 = 쥔 프로세스 없음 (로더 없음, 파일이 없는 경우 포함)
 *       -1 = 확인 자체가 실패 (errno 설정)
 * 얻은 공유 잠금은 close 로 바로 풀린다. 이 fd 가 clone() 으로 컨테이너에 복제되지 않도록 반드시 여기서 닫는다.
 */
static inline int myc_loader_alive(const char *path)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return (errno == ENOENT) ? 0 : -1;

    int result;
    int saved = 0;
    if (flock(fd, LOCK_SH | LOCK_NB) == 0) {
        result = 0;
    } else if (errno == EWOULDBLOCK) {
        result = 1;
    } else {
        saved = errno;
        result = -1;
    }
    close(fd);
    if (result == -1)
        errno = saved;
    return result;
}

#endif
