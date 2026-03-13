#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/*
 * Cross-platform helper that feeds JPEG frames into macvr-bridge-sim using the
 * local length-prefixed TCP protocol. The same source works as a native macOS
 * smoke-test tool and as a Windows sender when cross-compiled for Wine/GPTK.
 */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET socket_handle_t;
#define CLOSE_SOCKET closesocket
#define SOCK_LAST_ERROR WSAGetLastError()
#define INVALID_SOCKET_HANDLE INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int socket_handle_t;
#define CLOSE_SOCKET close
#define SOCK_LAST_ERROR errno
#define INVALID_SOCKET_HANDLE (-1)
#endif

typedef struct CLIOptions {
    const char *host;
    uint16_t port;
    const char *jpeg_file_path;
    int fps;
    uint64_t count;
    int reconnect_delay_ms;
    int max_jpeg_bytes;
    bool verbose;
} CLIOptions;

typedef enum ParseResult {
    ParseResultSuccess,
    ParseResultHelp,
    ParseResultVersion,
    ParseResultError
} ParseResult;

static volatile int g_should_stop = 0;

static const char *usage_text =
    "Usage: macvr-jpeg-sender [options]\n"
    "  --host <hostname>             Destination host (default: 127.0.0.1)\n"
    "  --port <port>                Destination TCP port (default: 44000)\n"
    "  --jpeg-file <path>           JPEG file to send (required)\n"
    "  --fps <value>                Send rate, 1-240 (default: 30)\n"
    "  --count <n>                  Frames to send, 0=infinite (default: 0)\n"
    "  --reconnect-delay-ms <ms>    Delay before reconnect, 10-30000 (default: 1000)\n"
    "  --max-jpeg-bytes <n>         Max accepted JPEG size, 1024-16000000 (default: 16000000)\n"
    "  --version                    Show build/release version\n"
    "  --verbose                    Enable debug logging\n"
    "  -h, --help                   Show this help\n";

static const char *sender_release_version = "0.1.0";

static void log_message(const char *level, const char *format, ...) {
    char timestamp[32];
    time_t now = time(NULL);
    struct tm local_tm;
#ifdef _WIN32
    localtime_s(&local_tm, &now);
#else
    localtime_r(&now, &local_tm);
#endif
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S", &local_tm);

    fprintf(stdout, "[%s] [%s] ", timestamp, level);

    va_list args;
    va_start(args, format);
    vfprintf(stdout, format, args);
    va_end(args);

    fputc('\n', stdout);
    fflush(stdout);
}

static void sleep_ms(int milliseconds) {
    if (milliseconds <= 0) {
        return;
    }
#ifdef _WIN32
    Sleep((DWORD) milliseconds);
#else
    struct timespec request;
    request.tv_sec = milliseconds / 1000;
    request.tv_nsec = (long) (milliseconds % 1000) * 1000000L;
    while (nanosleep(&request, &request) == -1 && errno == EINTR) {
    }
#endif
}

#ifndef _WIN32
static void handle_signal(int signal_number) {
    (void) signal_number;
    g_should_stop = 1;
}
#else
static BOOL WINAPI handle_console_ctrl(DWORD ctrl_type) {
    switch (ctrl_type) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
        g_should_stop = 1;
        return TRUE;
    default:
        return FALSE;
    }
}
#endif

static bool parse_u16(const char *value, uint16_t *result) {
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (end == value || *end != '\0' || parsed == 0 || parsed > UINT16_MAX) {
        return false;
    }
    *result = (uint16_t) parsed;
    return true;
}

static bool parse_int_range(const char *value, int min_value, int max_value, int *result) {
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < min_value || parsed > max_value) {
        return false;
    }
    *result = (int) parsed;
    return true;
}

static bool parse_u64(const char *value, uint64_t *result) {
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (end == value || *end != '\0') {
        return false;
    }
    *result = (uint64_t) parsed;
    return true;
}

static ParseResult parse_cli(int argc, char **argv, CLIOptions *options) {
    int index = 1;

    options->host = "127.0.0.1";
    options->port = 44000;
    options->jpeg_file_path = NULL;
    options->fps = 30;
    options->count = 0;
    options->reconnect_delay_ms = 1000;
    options->max_jpeg_bytes = 16000000;
    options->verbose = false;

    while (index < argc) {
        const char *arg = argv[index];

        if (strcmp(arg, "--host") == 0) {
            index += 1;
            if (index >= argc || argv[index][0] == '\0') {
                fprintf(stderr, "error: missing value for --host\n\n%s", usage_text);
                return ParseResultError;
            }
            options->host = argv[index];
        } else if (strcmp(arg, "--port") == 0) {
            index += 1;
            if (index >= argc || !parse_u16(argv[index], &options->port)) {
                fprintf(stderr, "error: invalid --port value\n\n%s", usage_text);
                return ParseResultError;
            }
        } else if (strcmp(arg, "--jpeg-file") == 0) {
            index += 1;
            if (index >= argc || argv[index][0] == '\0') {
                fprintf(stderr, "error: missing value for --jpeg-file\n\n%s", usage_text);
                return ParseResultError;
            }
            options->jpeg_file_path = argv[index];
        } else if (strcmp(arg, "--fps") == 0) {
            index += 1;
            if (index >= argc || !parse_int_range(argv[index], 1, 240, &options->fps)) {
                fprintf(stderr, "error: invalid --fps value\n\n%s", usage_text);
                return ParseResultError;
            }
        } else if (strcmp(arg, "--count") == 0) {
            index += 1;
            if (index >= argc || !parse_u64(argv[index], &options->count)) {
                fprintf(stderr, "error: invalid --count value\n\n%s", usage_text);
                return ParseResultError;
            }
        } else if (strcmp(arg, "--reconnect-delay-ms") == 0) {
            index += 1;
            if (index >= argc || !parse_int_range(argv[index], 10, 30000, &options->reconnect_delay_ms)) {
                fprintf(stderr, "error: invalid --reconnect-delay-ms value\n\n%s", usage_text);
                return ParseResultError;
            }
        } else if (strcmp(arg, "--max-jpeg-bytes") == 0) {
            index += 1;
            if (index >= argc || !parse_int_range(argv[index], 1024, 16000000, &options->max_jpeg_bytes)) {
                fprintf(stderr, "error: invalid --max-jpeg-bytes value\n\n%s", usage_text);
                return ParseResultError;
            }
        } else if (strcmp(arg, "--version") == 0) {
            return ParseResultVersion;
        } else if (strcmp(arg, "--verbose") == 0) {
            options->verbose = true;
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            fputs(usage_text, stdout);
            return ParseResultHelp;
        } else {
            fprintf(stderr, "error: unknown argument: %s\n\n%s", arg, usage_text);
            return ParseResultError;
        }

        index += 1;
    }

    if (options->jpeg_file_path == NULL) {
        fprintf(stderr, "error: --jpeg-file is required\n\n%s", usage_text);
        return ParseResultError;
    }

    return ParseResultSuccess;
}

static bool initialize_platform(void) {
#ifdef _WIN32
    WSADATA winsock_data;
    if (WSAStartup(MAKEWORD(2, 2), &winsock_data) != 0) {
        fprintf(stderr, "error: WSAStartup failed\n");
        return false;
    }
    SetConsoleCtrlHandler(handle_console_ctrl, TRUE);
#else
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
#endif
    return true;
}

static void shutdown_platform(void) {
#ifdef _WIN32
    WSACleanup();
#endif
}

static bool load_file_bytes(const char *path, unsigned char **data, size_t *length) {
    FILE *file = fopen(path, "rb");
    long file_size = 0;
    unsigned char *buffer = NULL;

    if (file == NULL) {
        return false;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return false;
    }

    file_size = ftell(file);
    if (file_size <= 0) {
        fclose(file);
        return false;
    }

    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return false;
    }

    buffer = (unsigned char *) malloc((size_t) file_size);
    if (buffer == NULL) {
        fclose(file);
        return false;
    }

    if (fread(buffer, 1, (size_t) file_size, file) != (size_t) file_size) {
        free(buffer);
        fclose(file);
        return false;
    }

    fclose(file);
    *data = buffer;
    *length = (size_t) file_size;
    return true;
}

static socket_handle_t connect_socket(const char *host, uint16_t port) {
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    struct addrinfo *entry = NULL;
    char port_string[16];
    socket_handle_t socket_fd = INVALID_SOCKET_HANDLE;
    int getaddrinfo_result = 0;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    snprintf(port_string, sizeof(port_string), "%u", (unsigned int) port);
    getaddrinfo_result = getaddrinfo(host, port_string, &hints, &result);
    if (getaddrinfo_result != 0) {
        return INVALID_SOCKET_HANDLE;
    }

    for (entry = result; entry != NULL; entry = entry->ai_next) {
        int opt = 1;
        socket_fd = (socket_handle_t) socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (socket_fd == INVALID_SOCKET_HANDLE) {
            continue;
        }

        setsockopt(socket_fd, IPPROTO_TCP, TCP_NODELAY, (const char *) &opt, (socklen_t) sizeof(opt));
        if (connect(socket_fd, entry->ai_addr, (socklen_t) entry->ai_addrlen) == 0) {
            freeaddrinfo(result);
            return socket_fd;
        }

        CLOSE_SOCKET(socket_fd);
        socket_fd = INVALID_SOCKET_HANDLE;
    }

    freeaddrinfo(result);
    return INVALID_SOCKET_HANDLE;
}

static bool send_all(socket_handle_t socket_fd, const unsigned char *data, size_t length) {
    size_t sent_total = 0;

    while (sent_total < length) {
        int sent_now = send(socket_fd, (const char *) (data + sent_total), (int) (length - sent_total), 0);
        if (sent_now <= 0) {
            return false;
        }
        sent_total += (size_t) sent_now;
    }

    return true;
}

int main(int argc, char **argv) {
    CLIOptions options;
    ParseResult parse_result;
    socket_handle_t socket_fd = INVALID_SOCKET_HANDLE;
    uint64_t frames_sent = 0;
    int log_interval = 1;

    parse_result = parse_cli(argc, argv, &options);
    if (parse_result == ParseResultHelp) {
        return EXIT_SUCCESS;
    }
    if (parse_result == ParseResultVersion) {
        fprintf(stdout, "macvr-jpeg-sender %s\n", sender_release_version);
        return EXIT_SUCCESS;
    }
    if (parse_result != ParseResultSuccess) {
        return EXIT_FAILURE;
    }

    if (!initialize_platform()) {
        return EXIT_FAILURE;
    }

    log_interval = options.fps * 2;
    if (log_interval < 1) {
        log_interval = 1;
    }

    log_message(
        "INFO",
        "Starting sender -> %s:%u, file=%s, fps=%d, count=%llu",
        options.host,
        (unsigned int) options.port,
        options.jpeg_file_path,
        options.fps,
        (unsigned long long) options.count
    );

    while (!g_should_stop && (options.count == 0 || frames_sent < options.count)) {
        unsigned char *jpeg_data = NULL;
        size_t jpeg_length = 0;
        uint32_t network_length = 0;

        if (socket_fd == INVALID_SOCKET_HANDLE) {
            socket_fd = connect_socket(options.host, options.port);
            if (socket_fd == INVALID_SOCKET_HANDLE) {
                log_message(
                    "WARN",
                    "Connect failed to %s:%u (error=%d); retrying in %dms",
                    options.host,
                    (unsigned int) options.port,
                    SOCK_LAST_ERROR,
                    options.reconnect_delay_ms
                );
                sleep_ms(options.reconnect_delay_ms);
                continue;
            }
            log_message("INFO", "Connected to %s:%u", options.host, (unsigned int) options.port);
        }

        if (!load_file_bytes(options.jpeg_file_path, &jpeg_data, &jpeg_length)) {
            log_message(
                "WARN",
                "Unable to read JPEG file %s; retrying in %dms",
                options.jpeg_file_path,
                options.reconnect_delay_ms
            );
            sleep_ms(options.reconnect_delay_ms);
            continue;
        }

        if (jpeg_length == 0 || jpeg_length > (size_t) options.max_jpeg_bytes || jpeg_length > UINT32_MAX) {
            log_message(
                "WARN",
                "Dropped JPEG size=%zuB (max=%dB)",
                jpeg_length,
                options.max_jpeg_bytes
            );
            free(jpeg_data);
            sleep_ms(options.reconnect_delay_ms);
            continue;
        }

        /* The bridge input protocol is `uint32_be length` followed by raw JPEG bytes. */
        network_length = htonl((uint32_t) jpeg_length);
        if (!send_all(socket_fd, (const unsigned char *) &network_length, sizeof(network_length))
            || !send_all(socket_fd, jpeg_data, jpeg_length)) {
            log_message("WARN", "Send failed (error=%d); reconnecting", SOCK_LAST_ERROR);
            CLOSE_SOCKET(socket_fd);
            socket_fd = INVALID_SOCKET_HANDLE;
            free(jpeg_data);
            sleep_ms(options.reconnect_delay_ms);
            continue;
        }

        frames_sent += 1;
        if (options.verbose || (frames_sent % (uint64_t) log_interval) == 0) {
            log_message(
                "INFO",
                "Sent frame=%llu size=%zuB",
                (unsigned long long) frames_sent,
                jpeg_length
            );
        }

        free(jpeg_data);

        if (!g_should_stop && (options.count == 0 || frames_sent < options.count)) {
            sleep_ms(1000 / options.fps);
        }
    }

    if (socket_fd != INVALID_SOCKET_HANDLE) {
        CLOSE_SOCKET(socket_fd);
    }

    shutdown_platform();
    log_message("INFO", "Stopped sender after %llu frames", (unsigned long long) frames_sent);
    return EXIT_SUCCESS;
}
