idf_component_register(
    SRCS "app_main.c" "ap_json.c" "ap_crypto.c" "ap_config.c"
         "ap_link.c" "ap_audio.c" "ap_font.c"
    INCLUDE_DIRS "."
    REQUIRES bsp nvs_flash esp_wifi esp_netif esp_event esp_timer
             esp_driver_usb_serial_jtag lwip mbedtls
    EMBED_FILES "noto16.bin"
)
