#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    int ignore = getenv("SWAPLIGHT_IGNORE_TERM") != NULL;
    if (ignore && signal(SIGTERM, SIG_IGN) == SIG_ERR) {
        return 1;
    }
    // Bound the fixture lifetime even if the runner stops.
    alarm(30);
    if (write(STDOUT_FILENO, ignore ? "I" : "R", 1) != 1) {
        return 2;
    }
    for (;;) {
        pause();
    }
}
