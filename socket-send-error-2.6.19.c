// gcc -o socket-send-error-2.6.19 socket-send-error-2.6.19.c
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>

int main() {
    int i;

    for (i = 0; i < 1000; i++) {
        int fd;
        ssize_t sent;
        struct sockaddr_in addr;

        fd = socket(PF_INET, SOCK_DGRAM, 0);
        if (fd < 0) {
            perror("socket()");
            return 1;
        }

        addr.sin_family = AF_INET;
        addr.sin_port = htons(2000);
        inet_aton("127.0.0.1", &addr.sin_addr);

        sent = sendto(fd, "", 0, 0, (struct sockaddr *)&addr, sizeof addr);
        if (sent < 0) {
            fprintf(stderr, "sendto fd %d: %s\n", fd, strerror(errno));
            break;
        }
    }

    fprintf(stderr, "Now try 'ping 127.0.0.1' in another shell\n");
    sleep(120);
    return 0;
}
