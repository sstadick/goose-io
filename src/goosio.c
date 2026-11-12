#include <stdint.h>
#include <stdlib.h>
#include <limits.h>

#pragma pack(push, 1)
typedef struct {
    uint8_t *data;
    int64_t len;
} goosio_slice;
#pragma pack(pop)

#ifdef _WIN32

#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#include <windows.h>

static wchar_t *goosio_wide_path_impl(goosio_slice path) {
    if (path.len <= 0 || path.len > INT_MAX) return NULL;
    for (int64_t i = 0; i < path.len; ++i) {
        if (path.data[i] == 0) return NULL;
    }
    int size = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)path.data,
        (int)path.len, NULL, 0);
    if (size <= 0 || (size_t)size >= SIZE_MAX / sizeof(wchar_t)) return NULL;
    wchar_t *wide = (wchar_t *)malloc(((size_t)size + 1) * sizeof(wchar_t));
    if (wide == NULL) return NULL;
    if (MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)path.data,
            (int)path.len, wide, size) != size) {
        free(wide);
        return NULL;
    }
    wide[size] = L'\0';
    return wide;
}

int32_t goosio_open_impl(goosio_slice path, int32_t write_mode) {
    wchar_t *wide = goosio_wide_path_impl(path);
    if (wide == NULL) return -1;
    int fd = write_mode
        ? _wopen(wide, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY | _O_NOINHERIT,
                 _S_IREAD | _S_IWRITE)
        : _wopen(wide, _O_RDONLY | _O_BINARY | _O_NOINHERIT);
    free(wide);
    return (int32_t)fd;
}

int64_t goosio_read_impl(int32_t fd, goosio_slice buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    unsigned int count = buffer.len > INT_MAX ? INT_MAX : (unsigned int)buffer.len;
    return (int64_t)_read(fd, buffer.data, count);
}

int64_t goosio_write_impl(int32_t fd, goosio_slice buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    unsigned int count = buffer.len > INT_MAX ? INT_MAX : (unsigned int)buffer.len;
    return (int64_t)_write(fd, buffer.data, count);
}

int32_t goosio_close_impl(int32_t fd) { return (int32_t)_close(fd); }

int64_t goosio_seek_impl(int32_t fd, int64_t offset) {
    return _lseeki64(fd, offset, 0);
}

#else

#include <errno.h>
#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>

static char *goosio_path_impl(goosio_slice path) {
    if (path.len <= 0 || (uint64_t)path.len >= SIZE_MAX) return NULL;
    for (int64_t i = 0; i < path.len; ++i) {
        if (path.data[i] == 0) return NULL;
    }
    char *copy = (char *)malloc((size_t)path.len + 1);
    if (copy == NULL) return NULL;
    for (int64_t i = 0; i < path.len; ++i) copy[i] = (char)path.data[i];
    copy[path.len] = '\0';
    return copy;
}

int32_t goosio_open_impl(goosio_slice path, int32_t write_mode) {
    char *copy = goosio_path_impl(path);
    if (copy == NULL) return -1;
    int flags = write_mode ? O_WRONLY | O_CREAT | O_TRUNC : O_RDONLY;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = write_mode ? open(copy, flags, 0666) : open(copy, flags);
    free(copy);
    return (int32_t)fd;
}

static size_t goosio_count_impl(int64_t len) {
    uint64_t count = (uint64_t)len;
    if (count > SIZE_MAX) count = SIZE_MAX;
#ifdef SSIZE_MAX
    if (count > (uint64_t)SSIZE_MAX) count = (uint64_t)SSIZE_MAX;
#endif
    return (size_t)count;
}

int64_t goosio_read_impl(int32_t fd, goosio_slice buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    ssize_t result;
    do {
        result = read(fd, buffer.data, goosio_count_impl(buffer.len));
    } while (result < 0 && errno == EINTR);
    return (int64_t)result;
}

int64_t goosio_write_impl(int32_t fd, goosio_slice buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    ssize_t result;
    do {
        result = write(fd, buffer.data, goosio_count_impl(buffer.len));
    } while (result < 0 && errno == EINTR);
    return (int64_t)result;
}

int32_t goosio_close_impl(int32_t fd) { return (int32_t)close(fd); }

int64_t goosio_seek_impl(int32_t fd, int64_t offset) {
    if ((int64_t)(off_t)offset != offset) return -1;
    off_t result;
    do { result = lseek(fd, (off_t)offset, SEEK_SET); } while (result < 0 && errno == EINTR);
    return (int64_t)result;
}

#endif

// The package loader resolves declared extern symbols from native parts even
// when optimized builds inline the c_headers definitions above them.
int32_t goosio_open(goosio_slice path, int32_t write_mode) {
    return goosio_open_impl(path, write_mode);
}
int64_t goosio_read(int32_t fd, goosio_slice buffer) {
    return goosio_read_impl(fd, buffer);
}
int64_t goosio_write(int32_t fd, goosio_slice buffer) {
    return goosio_write_impl(fd, buffer);
}
int32_t goosio_close(int32_t fd) { return goosio_close_impl(fd); }
int64_t goosio_seek(int32_t fd, int64_t offset) { return goosio_seek_impl(fd, offset); }
