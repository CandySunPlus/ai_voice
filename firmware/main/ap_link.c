#include "ap_link.h"
#include "ap_crypto.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "lwip/sockets.h"
#include "mbedtls/base64.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { LINK_CLOSED, LINK_CONNECTING, LINK_WELCOME, LINK_AUTHENTICATED };
static struct {
    int fd, phase;
    ap_host host;
    char device[33], device_nonce[33], session[33];
    uint8_t key[32], nonce[16];
    uint32_t tx_sequence, rx_sequence;
    int64_t deadline, last_rx, last_ping;
    size_t received;
    char line[8193], encoded[8193], decoded[6145], outgoing[1280];
    ap_json envelope, body;
    struct { uint32_t sequence; int64_t sent, retried; size_t length; char bytes[1280]; } pending[8];
    ap_link_message callback;
    void *user;
    const char *error;
} channel = { .fd = -1, .error = "尚未连接" };

static int64_t now(void) { return esp_timer_get_time(); }
static void close_link(const char *reason) {
    if (channel.fd >= 0) close(channel.fd);
    channel.fd = -1; channel.phase = LINK_CLOSED; channel.received = 0;
    memset(channel.key, 0, sizeof channel.key); memset(channel.nonce, 0, sizeof channel.nonce);
    memset(&channel.host, 0, sizeof channel.host); memset(channel.pending, 0, sizeof channel.pending);
    channel.error = reason;
}
void ap_link_init(ap_link_message cb, void *user) { channel.callback = cb; channel.user = user; }
void ap_link_close(void) { close_link("已断开主机"); }
bool ap_link_connected(void) { return channel.phase != LINK_CLOSED; }
bool ap_link_authenticated(void) { return channel.phase == LINK_AUTHENTICATED; }
const char *ap_link_error(void) { return channel.error; }
const uint8_t *ap_link_key(void) { return channel.key; }
const uint8_t *ap_link_nonce(void) { return channel.nonce; }
static bool write_line(const char *bytes, size_t count) {
    size_t sent = 0; int64_t deadline = now() + 150000;
    while (sent < count && now() < deadline) {
        ssize_t n = send(channel.fd, bytes + sent, count - sent, 0);
        if (n > 0) { sent += n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            fd_set set; FD_ZERO(&set); FD_SET(channel.fd, &set);
            struct timeval timeout = { .tv_usec = 20000 };
            int result = select(channel.fd + 1, NULL, &set, NULL, &timeout);
            if (result >= 0 || errno == EINTR) continue;
        }
        break;
    }
    if (sent != count) { close_link("控制发送失败，请重选主机"); return false; }
    return true;
}
bool ap_link_open(const ap_host *host, const char device[33]) {
    ap_link_close(); channel.host = *host; memcpy(channel.device, device, 33);
    channel.tx_sequence = 0; channel.rx_sequence = 0;
    uint8_t nonce[16]; esp_fill_random(nonce, sizeof nonce); ap_hex_encode(nonce, sizeof nonce, channel.device_nonce);
    struct sockaddr_in peer = { .sin_family = AF_INET, .sin_port = htons(host->port) };
    if (inet_pton(AF_INET, host->address, &peer.sin_addr) != 1) { close_link("主机地址无效，请重新配置"); return false; }
    channel.fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (channel.fd < 0 || fcntl(channel.fd, F_SETFL, O_NONBLOCK) < 0) { close_link("网络资源不足"); return false; }
    int result = connect(channel.fd, (struct sockaddr *)&peer, sizeof peer);
    if (result != 0 && errno != EINPROGRESS) { close_link("连接失败，请检查主机或重新配置"); return false; }
    channel.phase = LINK_CONNECTING; channel.deadline = now() + 2000000; channel.error = "正在连接已选主机";
    return true;
}
bool ap_link_send(const char *kind, const char *body) {
    if (!ap_link_authenticated() || channel.tx_sequence == UINT32_MAX) { close_link("会话已结束，请重选主机"); return false; }
    int slot = -1;
    if (strcmp(kind, "ack")) {
        for (unsigned i = 0; i < 8; ++i) if (!channel.pending[i].sequence) { slot = i; break; }
        if (slot < 0) { close_link("控制队列已满，已安全断开"); return false; }
    }
    char encoded[1040], mac[65]; size_t length; uint8_t digest[32];
    if (mbedtls_base64_encode((uint8_t *)encoded, sizeof encoded, &length, (const uint8_t *)body, strlen(body)) != 0) {
        close_link("控制消息过长"); return false;
    }
    encoded[length] = 0;
    uint32_t sequence = ++channel.tx_sequence;
    ap_control_mac(channel.key, channel.session, sequence, kind, encoded, digest); ap_hex_encode(digest, sizeof digest, mac);
    int n = snprintf(channel.outgoing, sizeof channel.outgoing,
                     "{\"seq\":%" PRIu32 ",\"kind\":\"%s\",\"body\":\"%s\",\"mac\":\"%s\"}\n", sequence, kind, encoded, mac);
    if (n < 0 || (size_t)n >= sizeof channel.outgoing) { close_link("控制消息过长"); return false; }
    if (!write_line(channel.outgoing, n)) return false;
    if (slot >= 0) {
        channel.pending[slot].sequence = sequence; channel.pending[slot].sent = now(); channel.pending[slot].retried = now();
        channel.pending[slot].length = n; memcpy(channel.pending[slot].bytes, channel.outgoing, n);
    }
    return true;
}
static bool acknowledge(uint32_t sequence) {
    char body[32]; snprintf(body, sizeof body, "{\"seq\":%" PRIu32 "}", sequence);
    return ap_link_send("ack", body);
}
static bool standard_base64(const char *s) {
    size_t n = strlen(s);
    if (!n || n % 4) return false;
    size_t padding = s[n - 1] == '=' ? (s[n - 2] == '=' ? 2 : 1) : 0;
    for (size_t i = 0; i < n - padding; ++i)
        if (!((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z') ||
              (s[i] >= '0' && s[i] <= '9') || s[i] == '+' || s[i] == '/')) return false;
    for (size_t i = n - padding; i < n; ++i) if (s[i] != '=') return false;
    if (padding) {
        const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const char *last = strchr(alphabet, s[n - padding - 1]);
        if (!last || ((last - alphabet) & (padding == 2 ? 15 : 3))) return false;
    }
    return true;
}
static bool lowercase_hex(const char *text, size_t length) {
    if (strlen(text) != length) return false;
    for (size_t i = 0; i < length; ++i)
        if (!((text[i] >= '0' && text[i] <= '9') || (text[i] >= 'a' && text[i] <= 'f'))) return false;
    return true;
}
static bool valid_body(const char *kind, const ap_json *d) {
    uint32_t number;
    if (!strcmp(kind, "ping")) return d->tokens[0].count == 0;
    if (!strcmp(kind, "ack"))
        return ap_json_u32(d, ap_json_get(d, 0, "seq"), &number) && number && number <= channel.tx_sequence;
    if (!strcmp(kind, "speak"))
        return ap_json_u32(d, ap_json_get(d, 0, "recording"), &number) && number;
    if (!strcmp(kind, "state")) {
        char phase[16], text[193], target[129];
        if (!ap_json_string(d, ap_json_get(d, 0, "phase"), phase, sizeof phase) ||
            !ap_json_string(d, ap_json_get(d, 0, "message"), text, sizeof text) ||
            !ap_json_string(d, ap_json_get(d, 0, "target"), target, sizeof target) ||
            !ap_json_is(d, ap_json_get(d, 0, "task"), "unknown")) return false;
        return !strcmp(phase, "idle") || !strcmp(phase, "target") || !strcmp(phase, "preparing") ||
               !strcmp(phase, "recording") || !strcmp(phase, "draining") || !strcmp(phase, "waiting") || !strcmp(phase, "error");
    }
    if (!strcmp(kind, "targets")) {
        int items = ap_json_get(d, 0, "items");
        if (items < 0 || d->tokens[items].type != AP_ARRAY || d->tokens[items].count > 12) return false;
        for (unsigned i = 0; i < d->tokens[items].count; ++i) {
            int item = ap_json_at(d, items, i); char id[129], text[49];
            if (!ap_json_string(d, ap_json_get(d, item, "id"), id, sizeof id) || !id[0] ||
                !ap_json_string(d, ap_json_get(d, item, "app"), text, sizeof text) ||
                !ap_json_string(d, ap_json_get(d, item, "title"), text, sizeof text)) return false;
        }
        return true;
    }
    return false;
}
static bool welcome(void) {
    ap_json *d = &channel.envelope;
    uint32_t version; char host_nonce[33], mac[65], text[192]; uint8_t expected[32], actual[32];
    if (!ap_json_u32(d, ap_json_get(d, 0, "v"), &version) || version != 1 ||
        !ap_json_is(d, ap_json_get(d, 0, "type"), "welcome") ||
        !ap_json_string(d, ap_json_get(d, 0, "nonce"), host_nonce, sizeof host_nonce) ||
        !lowercase_hex(host_nonce, 32) || !ap_hex_decode(host_nonce, channel.nonce, sizeof channel.nonce) ||
        !ap_json_string(d, ap_json_get(d, 0, "mac"), mac, sizeof mac) ||
        !lowercase_hex(mac, 64) || !ap_hex_decode(mac, actual, sizeof actual)) return false;
    snprintf(text, sizeof text, "welcome|%s|%s|%s|%s", channel.device, channel.host.id, channel.device_nonce, host_nonce);
    ap_hmac(channel.host.key, text, strlen(text), expected);
    if (!ap_constant_equal(expected, actual, sizeof actual)) return false;
    snprintf(text, sizeof text, "session|%s|%s", channel.device_nonce, host_nonce);
    ap_hmac(channel.host.key, text, strlen(text), channel.key); memcpy(channel.session, host_nonce, sizeof channel.session);
    memset(channel.host.key, 0, sizeof channel.host.key);
    channel.phase = LINK_AUTHENTICATED; channel.last_rx = now(); channel.last_ping = now();
    channel.error = "主机已鉴权";
    return ap_link_send("ready", "{}");
}
static bool control(void) {
    ap_json *d = &channel.envelope;
    char kind[16], mac[65]; uint32_t sequence; uint8_t actual[32], expected[32];
    if (!ap_json_u32(d, ap_json_get(d, 0, "seq"), &sequence) || !sequence ||
        !ap_json_string(d, ap_json_get(d, 0, "kind"), kind, sizeof kind) ||
        !ap_json_string(d, ap_json_get(d, 0, "body"), channel.encoded, sizeof channel.encoded) ||
        !ap_json_string(d, ap_json_get(d, 0, "mac"), mac, sizeof mac) ||
        !lowercase_hex(mac, 64) || !ap_hex_decode(mac, actual, sizeof actual)) return false;
    if (strcmp(kind, "ack") && strcmp(kind, "ping") && strcmp(kind, "targets") && strcmp(kind, "state") && strcmp(kind, "speak")) return false;
    ap_control_mac(channel.key, channel.session, sequence, kind, channel.encoded, expected);
    if (!ap_constant_equal(actual, expected, sizeof actual) || !standard_base64(channel.encoded)) return false;
    size_t length = 0;
    if (mbedtls_base64_decode((uint8_t *)channel.decoded, sizeof channel.decoded - 1, &length,
                              (const uint8_t *)channel.encoded, strlen(channel.encoded)) != 0) return false;
    channel.decoded[length] = 0;
    if (!ap_json_parse(&channel.body, channel.decoded, length) || !valid_body(kind, &channel.body)) return false;
    channel.last_rx = now();
    if (sequence <= channel.rx_sequence) return !strcmp(kind, "ack") || acknowledge(sequence);
    if (channel.rx_sequence == UINT32_MAX || sequence != channel.rx_sequence + 1) return false;
    channel.rx_sequence = sequence;
    if (!strcmp(kind, "ack")) {
        uint32_t acknowledged;
        if (!ap_json_u32(&channel.body, ap_json_get(&channel.body, 0, "seq"), &acknowledged) || !acknowledged || acknowledged > channel.tx_sequence) return false;
        for (unsigned i = 0; i < 8; ++i) if (channel.pending[i].sequence == acknowledged) channel.pending[i].sequence = 0;
        return true;
    }
    if (strcmp(kind, "ping") && (!channel.callback || !channel.callback(kind, &channel.body, channel.user))) return false;
    return acknowledge(sequence);
}
void ap_link_step(void) {
    if (channel.phase == LINK_CLOSED) return;
    int64_t current = now();
    if (channel.phase == LINK_CONNECTING) {
        if (current >= channel.deadline) { close_link("连接超时，请检查地址或重新配置"); return; }
        fd_set writable; FD_ZERO(&writable); FD_SET(channel.fd, &writable);
        struct timeval timeout = {0};
        int result = select(channel.fd + 1, NULL, &writable, NULL, &timeout);
        if (result < 0 && errno != EINTR) { close_link("连接失败"); return; }
        if (result <= 0) return;
        int error = 0; socklen_t size = sizeof error;
        if (getsockopt(channel.fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0 || error) { close_link("连接失败，请检查主机或重新配置"); return; }
        int n = snprintf(channel.outgoing, sizeof channel.outgoing,
                         "{\"v\":1,\"type\":\"hello\",\"device\":\"%s\",\"host\":\"%s\",\"nonce\":\"%s\"}\n",
                         channel.device, channel.host.id, channel.device_nonce);
        if (!write_line(channel.outgoing, n)) return;
        channel.phase = LINK_WELCOME; channel.deadline = now() + 2000000;
    }
    if (channel.phase == LINK_WELCOME && current >= channel.deadline) { close_link("主机鉴权超时"); return; }
    char incoming[512];
    for (unsigned batch = 0; batch < 4 && channel.phase != LINK_CLOSED; ++batch) {
        ssize_t n = recv(channel.fd, incoming, sizeof incoming, 0);
        if (n == 0) { close_link("主机断开，请重新选择"); return; }
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) close_link("网络断开，请重新选择");
            break;
        }
        for (ssize_t i = 0; i < n; ++i) {
            unsigned char c = incoming[i];
            if (c == '\n') {
                channel.line[channel.received] = 0;
                bool valid = ap_json_parse(&channel.envelope, channel.line, channel.received);
                channel.received = 0;
                if (valid) valid = channel.phase == LINK_WELCOME ? welcome() : control();
                if (!valid) { close_link("鉴权或协议错误，已安全断开"); return; }
            } else {
                if (!c || channel.received == sizeof channel.line - 1) { close_link("非法控制消息，已断开"); return; }
                channel.line[channel.received++] = c;
            }
        }
    }
    if (!ap_link_authenticated()) return;
    current = now();
    if (current - channel.last_rx >= 3000000) { close_link("主机心跳超时"); return; }
    for (unsigned i = 0; i < 8; ++i) if (channel.pending[i].sequence) {
        if (current - channel.pending[i].sent >= 2000000) { close_link("主机未确认操作，已断开"); return; }
        if (current - channel.pending[i].retried >= 500000) {
            if (!write_line(channel.pending[i].bytes, channel.pending[i].length)) return;
            channel.pending[i].retried = current;
        }
    }
    if (current - channel.last_ping >= 1000000) { channel.last_ping = current; ap_link_send("ping", "{}"); }
}
bool ap_json_quote(const char *s, char *out, size_t cap) {
    size_t n = 0;
    if (cap < 3) return false;
    out[n++] = '"';
    while (*s) {
        unsigned char c = *s++;
        if (c < 32 || c == '"' || c == '\\') {
            if (c < 32) {
                if (n + 6 + 2 > cap) return false;
                snprintf(out + n, cap - n, "\\u%04x", c); n += 6;
            } else {
                if (n + 2 + 2 > cap) return false;
                out[n++] = '\\'; out[n++] = c;
            }
        } else { if (n + 3 > cap) return false; out[n++] = c; }
    }
    out[n++] = '"'; out[n] = 0; return true;
}
