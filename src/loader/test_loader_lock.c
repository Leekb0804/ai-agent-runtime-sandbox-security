/*
 * test_loader_lock.c
 *
 * loader_lock.h 의 단위 테스트. 커널 프로그램, libbpf, sudo 가 필요 없다.
 * 임시 폴더에 잠금 파일을 만들어 검증하고 끝나면 지운다.
 * 종료 코드: 0 통과, 1 실패, 2 환경 오류
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include "loader_lock.h"

static int failures;

#define CHECK(cond, name) do { \
    if (cond) printf("PASS: %s\n", name); \
    else { printf("FAIL: %s\n", name); failures++; } \
} while (0)

int main(void)
{
    char dir[] = "/tmp/myc_lock_test.XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }
    char path[256];
    snprintf(path, sizeof(path), "%s/loader.lock", dir);

    /* 1. 잠금 파일이 없으면 로더 없음 */
    CHECK(myc_loader_alive(path) == 0, "파일 없음 -> 로더 없음(0)");

    /* 2. 잠금을 쥐고 있는 동안은 로더 있음 */
    int fd = myc_loader_lock_acquire(path);
    CHECK(fd >= 0, "잠금 획득 성공");
    CHECK(myc_loader_alive(path) == 1, "쥐고 있는 동안 -> 로더 있음(1)");

    /* 3. 이미 쥐고 있으면 두 번째 로더는 획득하지 못함 */
    int fd2 = myc_loader_lock_acquire(path);
    CHECK(fd2 < 0 && errno == EWOULDBLOCK, "이미 쥔 상태에서 두 번째 획득은 실패(EWOULDBLOCK)");
    if (fd2 >= 0) close(fd2);

    /* 4. exec 로 넘어가지 않도록 CLOEXEC 가 걸려 있음 */
    int fl = fcntl(fd, F_GETFD);
    CHECK(fl >= 0 && (fl & FD_CLOEXEC), "잠금 fd 에 CLOEXEC");

    /* 5. 닫으면 풀리고, 파일은 남음 */
    close(fd);
    CHECK(myc_loader_alive(path) == 0, "닫으면 -> 로더 없음(0)");
    CHECK(access(path, F_OK) == 0, "잠금 파일은 남아 있음");

    /* 6. 쥔 프로세스가 SIGKILL 로 죽어도 풀림 (크래시 경우) */
    int pfd[2];
    if (pipe(pfd) != 0) { perror("pipe"); return 2; }
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 2; }
    if (child == 0) {
        close(pfd[0]);
        int cfd = myc_loader_lock_acquire(path);
        char ok = (cfd >= 0) ? 'Y' : 'N';
        if (write(pfd[1], &ok, 1) != 1) _exit(2);
        pause();                         /* 부모가 죽일 때까지 잠금을 쥔 채 대기 */
        _exit(0);
    }
    close(pfd[1]);
    char ok = 0;
    ssize_t r = read(pfd[0], &ok, 1);
    close(pfd[0]);
    CHECK(r == 1 && ok == 'Y', "자식이 잠금 획득");
    CHECK(myc_loader_alive(path) == 1, "자식이 쥐는 동안 -> 로더 있음(1)");
    kill(child, SIGKILL);
    int status = 0;
    waitpid(child, &status, 0);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL, "자식이 SIGKILL 로 종료됨");
    CHECK(myc_loader_alive(path) == 0, "SIGKILL 뒤 -> 로더 없음(0)");

    /* 7. agent-run 의 확인이 잠깐 공유 잠금을 쥔 순간에 로더가 시작해도 재시도로 획득함 */
    if (pipe(pfd) != 0) { perror("pipe"); return 2; }
    child = fork();
    if (child < 0) { perror("fork"); return 2; }
    if (child == 0) {
        close(pfd[0]);
        int cfd = open(path, O_RDONLY);
        if (cfd < 0 || flock(cfd, LOCK_SH) != 0) _exit(2);
        char go = 'G';
        if (write(pfd[1], &go, 1) != 1) _exit(2);
        usleep(30 * 1000);               /* 30ms 동안 공유 잠금을 쥐고 있다가 */
        _exit(0);                        /* 종료하면서 풀림 */
    }
    close(pfd[1]);
    char go = 0;
    r = read(pfd[0], &go, 1);
    close(pfd[0]);
    int fd3 = (r == 1) ? myc_loader_lock_acquire(path) : -1;
    CHECK(fd3 >= 0, "공유 잠금이 잠깐 쥐어져 있어도 재시도로 획득");
    if (fd3 >= 0) close(fd3);
    waitpid(child, &status, 0);

    /* 8. 만들 수 없는 경로에서는 획득이 실패함 */
    CHECK(myc_loader_lock_acquire("/nonexistent_dir_myc/x.lock") < 0, "만들 수 없는 경로 -> 획득 실패");

    unlink(path);
    rmdir(dir);

    if (failures) { printf("FAILED: %d\n", failures); return 1; }
    printf("ALL PASSED\n");
    return 0;
}
