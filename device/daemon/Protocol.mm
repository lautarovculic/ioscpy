#import "Protocol.h"

#import <unistd.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <errno.h>

// 64-bit network-order helpers, since htonl/ntohl only cover 32 bits. Works on
// any host endianness; a no-op on big-endian.
static uint64_t hton64(uint64_t v) {
    uint32_t probe = 1;
    if (*(const uint8_t *)&probe == 1) {
        // Little-endian host: swap each half, then swap the halves.
        uint32_t lo = htonl((uint32_t)(v & 0xffffffffu));
        uint32_t hi = htonl((uint32_t)(v >> 32));
        return ((uint64_t)lo << 32) | hi;
    }
    return v;
}
static uint64_t ntoh64(uint64_t v) {
    return hton64(v); // byte reversal is its own inverse
}

// Read exactly len bytes, looping over short reads. Returns NO on EOF or error.
static BOOL readFull(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n < 0 && errno == EINTR) {
            continue; // interrupted by a signal, retry
        }
        if (n <= 0) {
            return NO;
        }
        got += (size_t)n;
    }
    return YES;
}

static BOOL writeFull(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n < 0 && errno == EINTR) {
            continue; // interrupted by a signal, retry
        }
        if (n <= 0) {
            return NO;
        }
        sent += (size_t)n;
    }
    return YES;
}

BOOL IOSPYReadFrame(int fd, IOSPYFrameHeader *header, NSData **payload) {
    uint8_t raw[IOSPY_HEADER_SIZE];
    if (!readFull(fd, raw, sizeof(raw))) {
        return NO;
    }

    uint32_t magic;
    memcpy(&magic, raw + 0, 4);
    if (ntohl(magic) != IOSPY_MAGIC) {
        return NO;
    }

    uint16_t version, type;
    uint32_t flags, length;
    uint64_t streamId, seq;
    memcpy(&version, raw + 4, 2);
    memcpy(&type, raw + 6, 2);
    memcpy(&flags, raw + 8, 4);
    memcpy(&streamId, raw + 12, 8);
    memcpy(&seq, raw + 20, 8);
    memcpy(&length, raw + 28, 4);

    header->version = ntohs(version);
    header->type = ntohs(type);
    header->flags = ntohl(flags);
    header->stream_id = ntoh64(streamId);
    header->seq = ntoh64(seq);
    header->length = ntohl(length);

    if (header->length > IOSPY_MAX_PAYLOAD) {
        return NO;
    }

    if (header->length == 0) {
        if (payload) {
            *payload = [NSData data];
        }
        return YES;
    }

    NSMutableData *body = [NSMutableData dataWithLength:header->length];
    if (!readFull(fd, body.mutableBytes, header->length)) {
        return NO;
    }
    if (payload) {
        *payload = body;
    }
    return YES;
}

static void fillHeader(uint8_t *raw, IOSPYMessageType type, uint64_t streamId, uint64_t seq,
                       uint32_t length) {
    uint32_t magic = htonl(IOSPY_MAGIC);
    uint16_t version = htons(IOSPY_PROTOCOL_VERSION);
    uint16_t t = htons((uint16_t)type);
    uint32_t flags = htonl(0);
    uint64_t sid = hton64(streamId);
    uint64_t sq = hton64(seq);
    uint32_t len = htonl(length);
    memcpy(raw + 0, &magic, 4);
    memcpy(raw + 4, &version, 2);
    memcpy(raw + 6, &t, 2);
    memcpy(raw + 8, &flags, 4);
    memcpy(raw + 12, &sid, 8);
    memcpy(raw + 20, &sq, 8);
    memcpy(raw + 28, &len, 4);
}

BOOL IOSPYWriteFrame(int fd, IOSPYMessageType type, uint64_t streamId, uint64_t seq, NSData *payload) {
    uint32_t length = (uint32_t)(payload ? payload.length : 0);
    uint8_t raw[IOSPY_HEADER_SIZE];
    fillHeader(raw, type, streamId, seq, length);

    // Send header and payload in one write so the frame isn't split into two
    // segments. Over usbmux that split costs a round trip per frame.
    if (length == 0) {
        return writeFull(fd, raw, sizeof(raw));
    }
    size_t total = sizeof(raw) + length;
    uint8_t *buffer = (uint8_t *)malloc(total);
    if (!buffer) {
        if (!writeFull(fd, raw, sizeof(raw))) {
            return NO;
        }
        return writeFull(fd, payload.bytes, length);
    }
    memcpy(buffer, raw, sizeof(raw));
    memcpy(buffer + sizeof(raw), payload.bytes, length);
    BOOL ok = writeFull(fd, buffer, total);
    free(buffer);
    return ok;
}

int IOSPYTryWriteFrame(int fd, IOSPYMessageType type, uint64_t streamId, uint64_t seq, NSData *payload) {
    uint32_t length = (uint32_t)(payload ? payload.length : 0);
    size_t total = IOSPY_HEADER_SIZE + length;
    uint8_t *buffer = (uint8_t *)malloc(total);
    if (!buffer) {
        return -1;
    }
    fillHeader(buffer, type, streamId, seq, length);
    if (length > 0) {
        memcpy(buffer + IOSPY_HEADER_SIZE, payload.bytes, length);
    }

    // MSG_DONTWAIT makes just this send non-blocking without changing the fd's
    // mode, since the read loop shares this socket on another thread.
    ssize_t n = send(fd, buffer, total, MSG_DONTWAIT);
    int result;
    if (n == (ssize_t)total) {
        result = 1; // fully sent
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS ||
                         errno == EINTR)) {
        // Transient: buffer full, out of buffers, or interrupted. Nothing was
        // written, so drop this frame and let the pump grab the newest next.
        result = 0;
    } else if (n < 0) {
        result = -1; // real error like EPIPE or ECONNRESET, tear down the pump
    } else {
        // Partial write: finish the rest blocking so the stream stays framed.
        result = writeFull(fd, buffer + n, total - (size_t)n) ? 1 : -1;
    }
    free(buffer);
    return result;
}
