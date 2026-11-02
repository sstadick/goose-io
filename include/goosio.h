#ifndef GOOSIO_H
#define GOOSIO_H

// c_headers places this after Goose's generated runtime and slice types.
#if defined(_MSC_VER)
#define GOOSIO_INLINE static __forceinline
#elif defined(__GNUC__) || defined(__clang__)
#define GOOSIO_INLINE static inline __attribute__((always_inline))
#else
#define GOOSIO_INLINE static inline
#endif

#if defined(__TINYC__)

// `goose run` resolves the externs from the native package. Optimized native
// builds use the always-inline definitions below instead.

#elif defined(_WIN32)

#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#include <windows.h>

GOOSIO_INLINE wchar_t *goosio_wide_path(sl_u8 path) {
    if (path.len <= 0 || path.len > 2147483647) return NULL;
    for (int64_t i = 0; i < path.len; ++i) {
        if (path.data[i] == 0) return NULL;
    }

    int size = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)path.data,
        (int)path.len, NULL, 0);
    if (size <= 0 || (size_t)size >= (size_t)-1 / sizeof(wchar_t)) return NULL;

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

GOOSIO_INLINE int32_t goosio_open(sl_u8 path, int32_t write_mode) {
    wchar_t *wide = goosio_wide_path(path);
    if (wide == NULL) return -1;
    int fd;
    if (write_mode) {
        fd = _wopen(wide, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY | _O_NOINHERIT,
                    _S_IREAD | _S_IWRITE);
    } else {
        fd = _wopen(wide, _O_RDONLY | _O_BINARY | _O_NOINHERIT);
    }
    free(wide);
    return (int32_t)fd;
}

GOOSIO_INLINE int64_t goosio_read(int32_t fd, sl_u8 buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    unsigned int count = buffer.len > 2147483647 ? 2147483647u : (unsigned int)buffer.len;
    return (int64_t)_read(fd, buffer.data, count);
}

GOOSIO_INLINE int64_t goosio_write(int32_t fd, sl_u8 buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    unsigned int count = buffer.len > 2147483647 ? 2147483647u : (unsigned int)buffer.len;
    return (int64_t)_write(fd, buffer.data, count);
}

GOOSIO_INLINE int32_t goosio_close(int32_t fd) {
    return (int32_t)_close(fd);
}

#else

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/types.h>
#include <unistd.h>

GOOSIO_INLINE char *goosio_path(sl_u8 path) {
    if (path.len <= 0 || (uint64_t)path.len >= (uint64_t)(size_t)-1) return NULL;
    for (int64_t i = 0; i < path.len; ++i) {
        if (path.data[i] == 0) return NULL;
    }
    char *copy = (char *)malloc((size_t)path.len + 1);
    if (copy == NULL) return NULL;
    for (int64_t i = 0; i < path.len; ++i) copy[i] = (char)path.data[i];
    copy[path.len] = '\0';
    return copy;
}

GOOSIO_INLINE int32_t goosio_open(sl_u8 path, int32_t write_mode) {
    char *copy = goosio_path(path);
    if (copy == NULL) return -1;
    int flags = write_mode ? O_WRONLY | O_CREAT | O_TRUNC : O_RDONLY;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = write_mode ? open(copy, flags, 0666) : open(copy, flags);
    free(copy);
    return (int32_t)fd;
}

GOOSIO_INLINE size_t goosio_count(int64_t len) {
    uint64_t count = (uint64_t)len;
    if (count > (uint64_t)(size_t)-1) count = (uint64_t)(size_t)-1;
#ifdef SSIZE_MAX
    if (count > (uint64_t)SSIZE_MAX) count = (uint64_t)SSIZE_MAX;
#else
    if (count > INT64_MAX) count = INT64_MAX;
#endif
    return (size_t)count;
}

GOOSIO_INLINE int64_t goosio_read(int32_t fd, sl_u8 buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    ssize_t result;
    do {
        result = read(fd, buffer.data, goosio_count(buffer.len));
    } while (result < 0 && errno == EINTR);
    return (int64_t)result;
}

GOOSIO_INLINE int64_t goosio_write(int32_t fd, sl_u8 buffer) {
    if (buffer.len < 0) return -1;
    if (buffer.len == 0) return 0;
    ssize_t result;
    do {
        result = write(fd, buffer.data, goosio_count(buffer.len));
    } while (result < 0 && errno == EINTR);
    return (int64_t)result;
}

GOOSIO_INLINE int32_t goosio_close(int32_t fd) {
    return (int32_t)close(fd);
}

#endif

#undef GOOSIO_INLINE
#endif
