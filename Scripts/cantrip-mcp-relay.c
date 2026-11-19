// cantrip-mcp-relay NAME [--backend KIND] [--tab ID]: the native twin of Scripts/cantrip-mcp.
//
// Every backend session starts one stdio process per relayed MCP server, so this relay runs many
// times at once (16 servers in each tab). The Python script costs about 8 MB of memory per copy;
// this one about 1 MB. It speaks the same protocol: it connects to the running Cantrip host's
// user-only socket, sends one hello line ({"server","backend","tab"}; the tab also comes from
// CANTRIP_TAB_ID) and then passes bytes both ways unchanged. No token ever reaches it.
//
// When Cantrip isn't running it runs the Python script beside it (Contents/Resources/bin), which
// answers every request with a visible error instead of hanging.
// Built by Scripts/assemble-app.sh into Contents/Resources/bin; MCPBackendConfig.relayScript
// prefers it to the script when it's there.
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static const char *option(int argc, char **argv, const char *name) {
    for (int i = 2; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return NULL;
}

static int write_all(int fd, const char *data, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, data, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        data += written;
        length -= (size_t)written;
    }
    return 0;
}

// Appends `text` to `out` as a JSON string body (no quotes); returns the new length or -1 when full.
static long json_escape(char *out, long used, long capacity, const char *text) {
    for (const unsigned char *c = (const unsigned char *)text; *c; c++) {
        char piece[8];
        int length;
        if (*c == '"' || *c == '\\') length = snprintf(piece, sizeof piece, "\\%c", *c);
        else if (*c < 0x20) length = snprintf(piece, sizeof piece, "\\u%04x", *c);
        else { piece[0] = (char)*c; length = 1; }
        if (used + length >= capacity) return -1;
        memcpy(out + used, piece, (size_t)length);
        used += length;
    }
    return used;
}

static long append(char *out, long used, long capacity, const char *text) {
    size_t length = strlen(text);
    if (used < 0 || used + (long)length >= capacity) return -1;
    memcpy(out + used, text, length);
    return used + (long)length;
}

static void socket_path(char *out, size_t capacity) {
    const char *override = getenv("CANTRIP_MCP_SOCKET");
    if (override && *override) { snprintf(out, capacity, "%s", override); return; }
    const char *home = getenv("HOME");
    char preferred[PATH_MAX];
    snprintf(preferred, sizeof preferred, "%s/.cache/Cantrip/mcp-relay.sock", home ? home : "");
    if (strlen(preferred) < 104) snprintf(out, capacity, "%s", preferred);
    else snprintf(out, capacity, "/tmp/cantrip-%d/mcp-relay.sock", (int)getuid());
}

// The Python relay beside this binary, for its "Cantrip isn't running" answers.
static void run_script(char **argv) {
    char self[PATH_MAX], script[PATH_MAX];
    if (!realpath(argv[0], self)) snprintf(self, sizeof self, "%s", argv[0]);
    snprintf(script, sizeof script, "%s/cantrip-mcp", dirname(self));
    argv[0] = script;
    execv(script, argv);
    fprintf(stderr, "Cantrip isn't running, so the MCP server %s (relayed through Cantrip) is unavailable.\n", argv[1]);
    _exit(1);
}

int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] == '-') {
        fputs("usage: cantrip-mcp-relay NAME [--backend KIND] [--tab ID]\n", stderr);
        return 2;
    }
    const char *backend = option(argc, argv, "--backend");
    const char *tab = option(argc, argv, "--tab");
    if (!tab) tab = getenv("CANTRIP_TAB_ID");

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    socket_path(address.sun_path, sizeof address.sun_path);
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0 || connect(connection, (struct sockaddr *)&address, sizeof address) != 0) {
        if (connection >= 0) close(connection);
        run_script(argv);
    }
    signal(SIGPIPE, SIG_IGN);

    // The same hello line the script sends (json.dumps' separators).
    char hello[4096];
    long capacity = sizeof hello, used = 0;
    used = append(hello, used, capacity, "{\"server\": \"");
    if (used >= 0) used = json_escape(hello, used, capacity, argv[1]);
    used = append(hello, used, capacity, "\", \"backend\": \"");
    if (used >= 0) used = json_escape(hello, used, capacity, backend ? backend : "");
    used = append(hello, used, capacity, "\", \"tab\": \"");
    if (used >= 0) used = json_escape(hello, used, capacity, tab ? tab : "");
    used = append(hello, used, capacity, "\"}\n");
    if (used < 0) { fputs("cantrip-mcp-relay: arguments too long\n", stderr); return 2; }
    if (write_all(connection, hello, (size_t)used) != 0) return 1;

    static char buffer[65536];
    int input_open = 1;
    char last = '\n';
    time_t closed_at = 0;
    for (;;) {
        struct pollfd fds[2] = {{connection, POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        int timeout = -1;
        if (!input_open) {
            // As the script does: after the client closes stdin, wait up to 5 s for the host's last replies.
            long left = 5000 - (long)(time(NULL) - closed_at) * 1000;
            if (left <= 0) return 0;
            timeout = (int)left;
        }
        int ready = poll(fds, input_open ? 2 : 1, timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return 1;
        }
        if (ready == 0) return 0;
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t count = read(connection, buffer, sizeof buffer);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) _exit(0);
            if (write_all(STDOUT_FILENO, buffer, (size_t)count) != 0) _exit(0);
        }
        if (input_open && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) {
                // The script sends every line newline-terminated, the last one included.
                if (last != '\n') write_all(connection, "\n", 1);
                shutdown(connection, SHUT_WR);
                input_open = 0;
                closed_at = time(NULL);
                continue;
            }
            last = buffer[count - 1];
            if (write_all(connection, buffer, (size_t)count) != 0) _exit(0);
        }
    }
}
