#include "ap_audio.h"
#include "ap_config.h"
#include "ap_font.h"
#include "ap_link.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "driver/usb_serial_jtag.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

typedef enum { PAGE_HOSTS, PAGE_TARGETS, PAGE_INPUT, PAGE_USB } page_type;
typedef struct { char id[129], app[49], title[49]; } input_target;
typedef struct { bsp_btn_t button; bsp_btn_ev_t event; } key_event;
static struct {
    ap_config config;
    char device[33];
    bool storage_ok, usb_ready, display_ready, audio_ready, wifi_ready, wifi_started;
    bool was_online, was_authenticated, ok_long, dirty, stopping, capturing, config_pending;
    unsigned host_index, target_index, target_count, wifi_index, wifi_attempts;
    int selected_host;
    int64_t wifi_deadline;
    page_type page;
    char phase[16], message[193], selected_target[129];
    uint32_t recording_counter, recording, ended_recording;
    input_target targets[12];
    lv_obj_t *heading, *status, *rows[3], *hint, *footer;
    size_t usb_used;
    bool usb_overflow;
    char usb_line[8193];
    ap_json usb_json;
} app = { .selected_host = -1, .page = PAGE_HOSTS, .dirty = true };
static QueueHandle_t keys;
static StaticQueue_t key_queue;
static uint8_t key_storage[16 * sizeof(key_event)];
static atomic_bool up_held, key_overflow, wifi_online;
static int64_t clock_us(void) { return esp_timer_get_time(); }
static void message(const char *text) {
    snprintf(app.message, sizeof app.message, "%s", text); app.dirty = true;
}
static void clear_target(void) {
    app.selected_target[0] = 0; app.target_count = 0; app.target_index = 0;
    strcpy(app.phase, "idle"); app.dirty = true;
}
static void cancel_recording(bool notify) {
    ap_audio_request_stop();
    if (notify && ap_link_authenticated()) ap_link_send("cancel", "{}");
    app.ended_recording = app.recording; app.recording = 0;
    app.stopping = false; app.capturing = false; app.dirty = true;
}
static void disconnect_host(const char *text) {
    cancel_recording(true); ap_link_close(); clear_target(); app.selected_host = -1;
    app.was_authenticated = false; app.page = PAGE_HOSTS; message(text);
}
static bool audio_busy(void) { return ap_audio_status(NULL) == AP_AUDIO_RUNNING; }
static void button_callback(bsp_btn_t button, bsp_btn_ev_t event, void *user) {
    (void)user;
    if (button == BSP_BTN_UP && (event == BSP_BTN_PRESS || event == BSP_BTN_RELEASE)) {
        atomic_store_explicit(&up_held, event == BSP_BTN_PRESS, memory_order_release);
        if (event == BSP_BTN_RELEASE) ap_audio_request_stop();
    }
    key_event key = { button, event };
    if (xQueueSend(keys, &key, 0) != pdTRUE) atomic_store(&key_overflow, true);
}
static void network_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)data;
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) atomic_store(&wifi_online, true);
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) atomic_store(&wifi_online, false);
}
static bool wifi_initialize(void) {
    if (esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) return false;
    if (!esp_netif_create_default_wifi_sta()) return false;
    if (esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_event, NULL) != ESP_OK ||
        esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_event, NULL) != ESP_OK) return false;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    return esp_wifi_init(&init) == ESP_OK && esp_wifi_set_storage(WIFI_STORAGE_RAM) == ESP_OK &&
           esp_wifi_set_mode(WIFI_MODE_STA) == ESP_OK;
}
static void wifi_attempt(unsigned index) {
    if (!app.wifi_ready || !app.config.wifi_count || !app.storage_ok) return;
    atomic_store(&wifi_online, false);
    if (app.wifi_started) esp_wifi_disconnect();
    app.wifi_index = index % app.config.wifi_count;
    wifi_config_t config = {0}; const ap_wifi *saved = &app.config.wifi[app.wifi_index];
    memcpy(config.sta.ssid, saved->ssid, strlen(saved->ssid));
    memcpy(config.sta.password, saved->password, strlen(saved->password));
    config.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    config.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
    config.sta.threshold.authmode = saved->password[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    config.sta.pmf_cfg.capable = true; config.sta.pmf_cfg.required = false;
    esp_err_t error = esp_wifi_set_config(WIFI_IF_STA, &config);
    memset(&config, 0, sizeof config);
    if (error == ESP_OK && !app.wifi_started) {
        error = esp_wifi_start(); if (error == ESP_OK) app.wifi_started = true;
    }
    if (error == ESP_OK) error = esp_wifi_set_ps(WIFI_PS_NONE);
    if (error == ESP_OK) error = esp_wifi_connect();
    app.wifi_deadline = clock_us() + 12000000;
    ++app.wifi_attempts;
    if (error != ESP_OK) message("WiFi连接失败，长按OK重新配置");
    app.dirty = true;
}
static void wifi_pause(void) {
    if (app.wifi_started) { esp_wifi_disconnect(); esp_wifi_stop(); app.wifi_started = false; }
    atomic_store(&wifi_online, false); app.was_online = false;
}
static void wifi_step(void) {
    if (app.page == PAGE_USB || app.config_pending || !app.config.wifi_count || !app.wifi_ready || !app.storage_ok) return;
    bool online = atomic_load(&wifi_online);
    if (online) app.wifi_deadline = clock_us() + 12000000;
    if (online != app.was_online) {
        app.was_online = online; app.dirty = true;
        if (!online && ap_link_connected()) disconnect_host("WiFi已断开，录音已取消");
        else if (online && app.page == PAGE_HOSTS) message("WiFi已连接，请显式选择主机");
    }
    if (!online && clock_us() >= app.wifi_deadline) {
        wifi_attempt(app.wifi_started ? app.wifi_index + 1 : 0);
        if (app.wifi_attempts > app.config.wifi_count) message("轮询WiFi连接失败，长按OK重配");
    }
}
static bool valid_target(const ap_json *d, int token, input_target *target) {
    return ap_json_string(d, ap_json_get(d, token, "id"), target->id, sizeof target->id) && target->id[0] &&
           ap_json_string(d, ap_json_get(d, token, "app"), target->app, sizeof target->app) &&
           ap_json_string(d, ap_json_get(d, token, "title"), target->title, sizeof target->title);
}
static bool on_message(const char *kind, const ap_json *d, void *unused) {
    (void)unused;
    if (!strcmp(kind, "targets")) {
        int items = ap_json_get(d, 0, "items");
        if (items < 0 || d->tokens[items].type != AP_ARRAY || d->tokens[items].count > 12) return false;
        // Validate the entire list before publishing any item.
        input_target target;
        for (unsigned i = 0; i < d->tokens[items].count; ++i) {
            if (!valid_target(d, ap_json_at(d, items, i), &target)) return false;
            for (unsigned j = 0; j < i; ++j) {
                char previous[129]; int item = ap_json_at(d, items, j);
                if (!ap_json_string(d, ap_json_get(d, item, "id"), previous, sizeof previous) || !strcmp(target.id, previous)) return false;
            }
        }
        app.target_count = d->tokens[items].count; app.target_index = 0;
        for (unsigned i = 0; i < app.target_count; ++i) valid_target(d, ap_json_at(d, items, i), &app.targets[i]);
        if (app.page != PAGE_INPUT) app.page = PAGE_TARGETS;
        app.dirty = true; return true;
    }
    if (!strcmp(kind, "state")) {
        char phase[16], text[193], target[129];
        if (!ap_json_string(d, ap_json_get(d, 0, "phase"), phase, sizeof phase) ||
            !ap_json_string(d, ap_json_get(d, 0, "message"), text, sizeof text) ||
            !ap_json_string(d, ap_json_get(d, 0, "target"), target, sizeof target) ||
            !ap_json_is(d, ap_json_get(d, 0, "task"), "unknown")) return false;
        if (strcmp(phase, "idle") && strcmp(phase, "target") && strcmp(phase, "preparing") && strcmp(phase, "recording") &&
            strcmp(phase, "draining") && strcmp(phase, "waiting") && strcmp(phase, "error")) return false;
        if ((strcmp(phase, "preparing") && strcmp(phase, "recording")) ||
            (app.selected_target[0] && strcmp(target, app.selected_target))) {
            if (app.recording) cancel_recording(false);
        }
        strcpy(app.phase, phase); strcpy(app.selected_target, target); message(text); return true;
    }
    if (!strcmp(kind, "speak")) {
        uint32_t recording;
        if (!ap_json_u32(d, ap_json_get(d, 0, "recording"), &recording) || !recording) return false;
        if (recording == app.ended_recording && !app.recording) return true; // Release raced an already queued speak.
        if (recording != app.recording || app.selected_host < 0 || app.page != PAGE_INPUT) return false;
        if (app.stopping || !atomic_load_explicit(&up_held, memory_order_acquire)) return true;
        if (app.capturing) return false; // New sequence must not re-trigger an old speak.
        if (!ap_audio_start(&app.config.hosts[app.selected_host], ap_link_key(), ap_link_nonce(), recording)) return false;
        app.capturing = true; strcpy(app.phase, "recording"); message("正在录音，松开上键结束"); return true;
    }
    return false;
}
static void return_to_targets(void) {
    if (app.recording || audio_busy()) { message("录音中不可切换目标"); return; }
    if (!ap_link_authenticated()) { disconnect_host("请重新选择主机"); return; }
    ap_link_send("cancel", "{}");
    app.selected_target[0] = 0; app.target_count = 0; app.target_index = 0;
    strcpy(app.phase, "idle"); app.page = PAGE_TARGETS;
    if (ap_link_send("list", "{}")) message("正在请求输入目标");
}
static void begin_recording(void) {
    if (app.page != PAGE_INPUT || !atomic_load(&up_held) || app.recording || audio_busy() || !ap_link_authenticated()) return;
    if (!app.display_ready || !app.audio_ready) { message("显示或音频不可用，拒绝开始录音"); return; }
    if (!app.selected_target[0] || (strcmp(app.phase, "target") && strcmp(app.phase, "waiting"))) {
        message("请先确认目标与输入焦点"); return;
    }
    if (app.recording_counter == UINT32_MAX) { disconnect_host("录音编号已用尽，请重选主机"); return; }
    app.recording = ++app.recording_counter; app.stopping = false; app.capturing = false;
    char body[48]; snprintf(body, sizeof body, "{\"recording\":%" PRIu32 "}", app.recording);
    if (ap_link_send("start", body)) { strcpy(app.phase, "preparing"); message("准备输入法与音频通路，请继续按住"); }
}
static void audio_step(void) {
    if (!app.recording) return;
    uint32_t last = 0; ap_audio_state state = ap_audio_status(&last);
    if (!atomic_load(&up_held)) { app.stopping = true; ap_audio_request_stop(); }
    if (app.capturing && state == AP_AUDIO_ERROR) {
        cancel_recording(true); strcpy(app.phase, "error"); message("音频读取或网络发送失败，已取消"); return;
    }
    if (app.capturing && state == AP_AUDIO_LIMIT) app.stopping = true;
    if (!app.stopping || state == AP_AUDIO_RUNNING) return;
    char body[80];
    snprintf(body, sizeof body, "{\"recording\":%" PRIu32 ",\"last\":%" PRIu32 "}", app.recording, app.capturing ? last : 0);
    app.ended_recording = app.recording; app.recording = 0; app.capturing = false; app.stopping = false;
    if (ap_link_send("stop", body)) { strcpy(app.phase, "draining"); message("已停止采集，正在排空尾部音频"); }
}
static void flush_usb(void) {
    if (!app.usb_ready) return;
    uint8_t bytes[128];
    for (unsigned batch = 0; batch < 32; ++batch)
        if (usb_serial_jtag_read_bytes(bytes, sizeof bytes, 0) <= 0) break;
    app.usb_used = 0; app.usb_overflow = false;
    memset(app.usb_line, 0, sizeof app.usb_line);
}
static void request_configuration(void) {
    disconnect_host("正在停止音频，准备USB配置");
    app.config_pending = true;
    // The configuration gate opens only after the physical long press AND worker completion.
    if (!ap_audio_halt(NULL)) message("音频线程停止中，暂不接受USB配置");
}
static void configuration_step(void) {
    if (!app.config_pending || audio_busy()) return;
    wifi_pause(); flush_usb(); app.page = PAGE_USB; app.config_pending = false;
    message(app.usb_ready ? "物理配置模式：115200 JSONL" : "USB驱动不可用，请重启检查");
}
static void choose_host(void) {
    if (audio_busy()) { message("音频线程尚未停止，请稍后"); return; }
    if (!app.storage_ok) { message("存储错误，长按OK进入配置恢复"); return; }
    if (!app.config.host_count) { message("未配对主机，长按OK进入USB配置"); return; }
    if (!atomic_load(&wifi_online)) { message("WiFi尚未连接，长按OK重配"); return; }
    cancel_recording(false); clear_target(); app.selected_host = app.host_index;
    app.recording_counter = 0; app.ended_recording = 0;
    if (ap_link_open(&app.config.hosts[app.host_index], app.device)) message("正在连接所选主机并验证密钥");
    else message(ap_link_error());
}
static void choose_target(void) {
    if (app.recording || audio_busy()) return;
    if (!app.target_count) { ap_link_send("list", "{}"); message("未发现目标，请在Mac打开可编辑窗口"); return; }
    char quoted[772], body[800]; input_target *target = &app.targets[app.target_index];
    if (!ap_json_quote(target->id, quoted, sizeof quoted)) { disconnect_host("输入目标标识无法编码"); return; }
    snprintf(body, sizeof body, "{\"id\":%s}", quoted);
    if (!ap_link_send("select", body)) return;
    strcpy(app.selected_target, target->id); strcpy(app.phase, "selecting"); app.page = PAGE_INPUT;
    message("正在确认目标与输入焦点");
}
static void handle_key(key_event key) {
    if (key.button == BSP_BTN_OK && key.event == BSP_BTN_PRESS) app.ok_long = false;
    if (key.button == BSP_BTN_OK && key.event == BSP_BTN_LONG) {
        app.ok_long = true;
        if (app.page == PAGE_USB) {
            flush_usb(); app.page = PAGE_HOSTS; app.wifi_attempts = 0; app.wifi_deadline = 0;
            message("已退出USB配置，请选择主机");
        } else if (app.page == PAGE_HOSTS && !ap_link_connected()) request_configuration();
        else disconnect_host("已退出会话，输入目标已清除");
        return;
    }
    if (app.page == PAGE_USB || app.config_pending) return;
    if (key.button == BSP_BTN_DOWN && key.event == BSP_BTN_LONG && app.page == PAGE_HOSTS && !ap_link_connected()) {
        if (app.config.wifi_count > 1) { wifi_attempt(app.wifi_index + 1); message("已切换到下一个保存的WiFi"); }
        return;
    }
    if (key.button == BSP_BTN_UP && key.event == BSP_BTN_RELEASE) {
        if (app.recording) { app.stopping = true; ap_audio_request_stop(); }
        return;
    }
    if (key.event == BSP_BTN_PRESS) {
        if (key.button == BSP_BTN_UP && app.page == PAGE_INPUT) { begin_recording(); return; }
        if (key.button == BSP_BTN_DOWN && app.page == PAGE_INPUT) {
            if (app.recording || audio_busy()) { cancel_recording(true); strcpy(app.phase, "idle"); message("已取消；确认焦点后重新选择目标"); }
            else return_to_targets();
            return;
        }
        if (app.recording || audio_busy()) return;
        if (app.page == PAGE_HOSTS && app.config.host_count && !ap_link_connected()) {
            if (key.button == BSP_BTN_UP) app.host_index = (app.host_index + app.config.host_count - 1) % app.config.host_count;
            if (key.button == BSP_BTN_DOWN) app.host_index = (app.host_index + 1) % app.config.host_count;
            app.dirty = true;
        } else if (app.page == PAGE_TARGETS && app.target_count) {
            if (key.button == BSP_BTN_UP) app.target_index = (app.target_index + app.target_count - 1) % app.target_count;
            if (key.button == BSP_BTN_DOWN) app.target_index = (app.target_index + 1) % app.target_count;
            app.dirty = true;
        }
    }
    if (key.button == BSP_BTN_OK && key.event == BSP_BTN_CLICK && !app.ok_long) {
        if (app.recording || audio_busy()) { message("录音中不可切换目标或主机"); return; }
        if (app.page == PAGE_HOSTS && !ap_link_connected()) choose_host();
        else if (app.page == PAGE_TARGETS) choose_target();
        else if (app.page == PAGE_INPUT) return_to_targets();
    }
}
static void usb_reply(const char *reply) {
    const size_t length = strlen(reply); size_t written = 0;
    int64_t deadline = clock_us() + 200000;
    while (written < length && clock_us() < deadline) {
        int n = usb_serial_jtag_write_bytes(reply + written, length - written, pdMS_TO_TICKS(20));
        if (n <= 0) break;
        written += n;
    }
}
static void usb_command(void) {
    if (!ap_json_parse(&app.usb_json, app.usb_line, app.usb_used)) { usb_reply("{\"ok\":false,\"error\":\"invalid_json\"}\n"); return; }
    ap_json *d = &app.usb_json;
    if (ap_json_is(d, ap_json_get(d, 0, "op"), "info")) {
        char reply[160]; snprintf(reply, sizeof reply,
            "{\"ok\":true,\"device\":\"%s\",\"board\":\"ai-passport-esp32c3-8mb\",\"protocol\":1}\n", app.device);
        usb_reply(reply);
    } else if (ap_json_is(d, ap_json_get(d, 0, "op"), "configure")) {
        esp_err_t error = ap_config_merge(&app.config, d);
        if (error == ESP_OK) {
            app.storage_ok = true; app.host_index = 0; app.wifi_index = 0;
            usb_reply("{\"ok\":true}\n"); message("配置已保存；长按OK退出并选择主机");
        } else usb_reply("{\"ok\":false,\"error\":\"invalid_configuration_or_storage\"}\n");
    } else if (ap_json_is(d, ap_json_get(d, 0, "op"), "erase")) {
        if (ap_config_erase(&app.config) == ESP_OK) {
            app.storage_ok = true; app.host_index = 0; app.wifi_index = 0;
            usb_reply("{\"ok\":true}\n"); message("已清除本应用WiFi与配对，设备ID保留");
        } else usb_reply("{\"ok\":false,\"error\":\"storage\"}\n");
    } else usb_reply("{\"ok\":false,\"error\":\"unsupported_operation\"}\n");
}
static void usb_step(void) {
    if (!app.usb_ready) return;
    unsigned char bytes[128];
    for (unsigned batch = 0; batch < 8; ++batch) {
        int n = usb_serial_jtag_read_bytes(bytes, sizeof bytes, 0);
        if (n <= 0) break;
        if (app.page != PAGE_USB) continue; // Gate closed: discard, never buffer future requests.
        for (int i = 0; i < n; ++i) {
            if (bytes[i] == '\n') {
                app.usb_line[app.usb_used] = 0;
                if (!app.usb_overflow) usb_command();
                else usb_reply("{\"ok\":false,\"error\":\"line_too_long\"}\n");
                memset(app.usb_line, 0, sizeof app.usb_line); app.usb_used = 0; app.usb_overflow = false;
            } else if (!bytes[i] || app.usb_used == sizeof app.usb_line - 1) app.usb_overflow = true;
            else if (!app.usb_overflow) app.usb_line[app.usb_used++] = bytes[i];
        }
    }
    memset(bytes, 0, sizeof bytes);
}
static lv_obj_t *label(int y, int height) {
    lv_obj_t *object = lv_label_create(lv_screen_active());
    if (!object) return NULL;
    lv_obj_set_pos(object, 20, y); lv_obj_set_size(object, 200, height);
    lv_label_set_long_mode(object, LV_LABEL_LONG_SCROLL_CIRCULAR);
    return object;
}
static bool display_initialize(void) {
    if (bsp_display_init() != ESP_OK || !bsp_lvgl_init() || !bsp_lvgl_lock(1000)) return false;
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x0b1527), 0);
    lv_obj_set_style_text_color(screen, lv_color_hex(0xe2edf5), 0);
    lv_obj_set_style_text_font(screen, &ap_font_chinese, 0);
    app.heading = label(22, 22); app.status = label(56, 22);
    for (unsigned i = 0; i < 3; ++i) app.rows[i] = label(92 + i * 48, 42);
    app.hint = label(246, 38); app.footer = label(287, 18);
    bool ok = app.heading && app.status && app.hint && app.footer && app.rows[0] && app.rows[1] && app.rows[2];
    if (ok) {
        lv_obj_set_style_text_color(app.heading, lv_color_hex(0x65e0ce), 0);
        lv_obj_set_style_text_color(app.footer, lv_color_hex(0x8c9db6), 0);
        bsp_display_backlight(65);
    }
    bsp_lvgl_unlock(); return ok;
}
static void set_text(lv_obj_t *label_object, const char *text) {
    char visible[1550]; ap_display_text(text, visible, sizeof visible); lv_label_set_text(label_object, visible);
}
static const char *phase_title(void) {
    if (!strcmp(app.phase, "preparing")) return "准备中";
    if (!strcmp(app.phase, "recording")) return "正在录音";
    if (!strcmp(app.phase, "draining")) return "排空音频";
    if (!strcmp(app.phase, "waiting")) return "等待出字";
    if (!strcmp(app.phase, "selecting")) return "确认目标";
    if (!strcmp(app.phase, "error")) return "错误";
    if (!strcmp(app.phase, "target")) return "准备就绪";
    return "待命";
}
static void render(void) {
    if (!app.dirty || !app.display_ready || !bsp_lvgl_lock(20)) return;
    app.dirty = false;
    for (unsigned i = 0; i < 3; ++i) set_text(app.rows[i], "");
    set_text(app.footer, "任务：未知  数量：不可用");
    set_text(app.status, app.message);
    if (app.page == PAGE_USB) {
        set_text(app.heading, "USB 物理配置模式");
        set_text(app.rows[0], "115200 / JSONL\n仅本模式接受配置");
        char counts[96]; snprintf(counts, sizeof counts, "已保存 WiFi：%u / 4\n已配对主机：%u / 4", app.config.wifi_count, app.config.host_count);
        set_text(app.rows[1], counts); set_text(app.rows[2], "凭证不回显\n未启用Flash加密");
        set_text(app.hint, "在Mac完成配置\n长按OK退出配置");
    } else if (app.page == PAGE_HOSTS) {
        set_text(app.heading, "选择主机");
        unsigned start = app.host_index > 1 ? app.host_index - 1 : 0;
        for (unsigned i = 0; i < 3 && start + i < app.config.host_count; ++i) {
            char text[100]; unsigned item = start + i;
            snprintf(text, sizeof text, "%s %s\n%s", item == app.host_index ? ">" : " ", app.config.hosts[item].name, app.config.hosts[item].address);
            set_text(app.rows[i], text);
        }
        if (!app.config.host_count) set_text(app.rows[0], "尚未配对\n长按OK进入USB配置");
        set_text(app.hint, "上/下选择  OK连接\n长OK配置  长下换WiFi");
    } else if (app.page == PAGE_TARGETS) {
        set_text(app.heading, "选择输入目标");
        unsigned start = app.target_index > 1 ? app.target_index - 1 : 0;
        for (unsigned i = 0; i < 3 && start + i < app.target_count; ++i) {
            unsigned item = start + i; char text[120];
            snprintf(text, sizeof text, "%s %s\n%s", item == app.target_index ? ">" : " ", app.targets[item].app, app.targets[item].title);
            set_text(app.rows[i], text);
        }
        if (!app.target_count) set_text(app.rows[0], "暂无可确认的输入目标\n请检查Mac辅助功能权限");
        set_text(app.hint, "上/下选择  OK确认\n长按OK退出会话");
    } else {
        set_text(app.heading, phase_title());
        bool found = false;
        for (unsigned i = 0; i < app.target_count; ++i) if (!strcmp(app.targets[i].id, app.selected_target)) {
            set_text(app.rows[0], app.targets[i].app); set_text(app.rows[1], app.targets[i].title); found = true; break;
        }
        if (!found) set_text(app.rows[0], "输入目标已清除");
        set_text(app.rows[2], "不自动发送或执行\n音频不保存到Flash");
        set_text(app.hint, "按住上键说话  下键取消\nOK选目标  长OK退出");
    }
    bsp_lvgl_unlock();
}
void app_main(void) {
    keys = xQueueCreateStatic(16, sizeof(key_event), key_storage, &key_queue);
    app.storage_ok = ap_config_load(&app.config, app.device) == ESP_OK;
    if (!app.storage_ok) { memset(&app.config, 0, sizeof app.config); app.config.version = 1; }
    app.display_ready = display_initialize();
    usb_serial_jtag_driver_config_t usb = { .tx_buffer_size = 512, .rx_buffer_size = 2048 };
    app.usb_ready = usb_serial_jtag_driver_install(&usb) == ESP_OK;
    app.audio_ready = ap_audio_init(); app.wifi_ready = wifi_initialize();
    ap_link_init(on_message, NULL); strcpy(app.phase, "idle");
    bool buttons = bsp_button_init(button_callback, NULL) == ESP_OK;
    if (!buttons) message("按键初始化失败，请检查硬件后重启");
    else if (!app.storage_ok) message("本应用存储异常，长按OK物理恢复");
    else if (!app.audio_ready || !app.wifi_ready) message("音频或WiFi初始化失败，请重启");
    else message("长按OK配置；已配置则选择主机");
    for (;;) {
        if (atomic_exchange(&key_overflow, false)) disconnect_host("按键队列溢出，已安全取消");
        key_event key;
        while (xQueueReceive(keys, &key, 0) == pdTRUE) handle_key(key);
        configuration_step(); usb_step(); wifi_step(); ap_link_step();
        bool authenticated = ap_link_authenticated();
        if (authenticated && !app.was_authenticated) {
            app.page = PAGE_TARGETS; app.recording_counter = 0;
            message("已鉴权，正在获取输入目标"); ap_link_send("list", "{}");
        }
        if (app.selected_host >= 0 && !ap_link_connected()) {
            const char *reason = ap_link_error();
            cancel_recording(false); clear_target(); app.selected_host = -1; app.page = PAGE_HOSTS; message(reason);
        }
        app.was_authenticated = ap_link_authenticated();
        audio_step(); render(); vTaskDelay(pdMS_TO_TICKS(10));
    }
}
