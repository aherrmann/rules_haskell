#ifdef _MSC_VER
#include <process.h>
#else
#include <unistd.h>
#include <stdio.h>
#endif /*_MSC_VER*/

const char *WORKSPACE = "{:workspace:}";
const char *CC = "{:cc:}";

int main(int argc, char **argv) {
    argv[0] = (char *)CC;
    int r =
#   ifdef _MSC_VER
        _execv
#   else
        execv
#   endif /*_MSC_VER*/
        (CC, argv);
    if (r == -1) {
        perror(nullptr);
        return 1;
    }
}

// vim: ft=cpp
