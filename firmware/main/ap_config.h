#pragma once
#include "ap_json.h"
#include "esp_err.h"
#include <stdint.h>
#define AP_NETWORKS 4
#define AP_HOSTS 4
typedef struct { char ssid[33], password[65]; } ap_wifi;
typedef struct { char id[33], name[49], address[16]; uint8_t key[32]; uint16_t port; } ap_host;
typedef struct { uint32_t version; uint8_t wifi_count, host_count; ap_wifi wifi[AP_NETWORKS]; ap_host hosts[AP_HOSTS]; } ap_config;
esp_err_t ap_config_load(ap_config *config, char device[33]);
// All fields validate before one atomic NVS blob update; merge SSIDs and host IDs.
esp_err_t ap_config_merge(ap_config *config, const ap_json *request);
esp_err_t ap_config_erase(ap_config *config);
