#include "ap_json.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static ap_json document;
static bool parse(const char *text) { return ap_json_parse(&document, text, strlen(text)); }
int main(void) {
    // Duplicate fields must never reinterpret a credential, sequence or operation.
    assert(!parse("{\"op\":\"info\",\"op\":\"erase\"}"));
    assert(!parse("{\"op\":\"info\",\"\\u006fp\":\"erase\"}"));
    assert(!parse("{\"x\":{\"seq\":1,\"seq\":2}}"));
    assert(!parse("{\"x\":1,}"));
    assert(!parse("{\"x\":[1,]}"));
    assert(!parse("{\"x\":01}"));
    assert(!parse("{\"x\":true}garbage"));
    assert(!parse("{\"x\":\"\\u0000\"}"));
    assert(!parse("{\"x\":\"\\ud800\"}"));
    assert(!parse("{\"x\":\"\\udc00\"}"));
    assert(!parse("{\"x\":\"\\ud800\\u0041\"}"));
    assert(!parse("{\"x\":\"\xc0\xaf\"}"));
    assert(!parse("{\"x\":\"\xed\xa0\x80\"}"));
    assert(!parse("{\"x\":\"\xf4\x90\x80\x80\"}"));
    assert(parse("{\"seq\":4294967295,\"text\":\"中文\\ud83d\\ude00\",\"nested\":[{},[]]}"));
    uint32_t number = 0;
    assert(ap_json_u32(&document, ap_json_get(&document, 0, "seq"), &number) && number == UINT32_MAX);
    char text[32];
    assert(ap_json_string(&document, ap_json_get(&document, 0, "text"), text, sizeof text));
    assert(!strcmp(text, "中文\xf0\x9f\x98\x80"));
    char tiny[3];
    assert(!ap_json_string(&document, ap_json_get(&document, 0, "text"), tiny, sizeof tiny));
    const char *bad_numbers[] = { "{\"seq\":4294967296}", "{\"seq\":-1}", "{\"seq\":1.0}", "{\"seq\":1e0}", "{\"seq\":\"1\"}", "{\"seq\":true}" };
    for (unsigned i = 0; i < sizeof bad_numbers / sizeof bad_numbers[0]; ++i) {
        assert(parse(bad_numbers[i]));
        assert(!ap_json_u32(&document, ap_json_get(&document, 0, "seq"), &number));
    }
    assert(!parse("{\"x\":[[[[[[[[[0]]]]]]]]]}"));
    char many[2048]; size_t used = 0;
    used += snprintf(many + used, sizeof many - used, "{\"x\":[");
    for (unsigned i = 0; i < 260; ++i) used += snprintf(many + used, sizeof many - used, "%s0", i ? "," : "");
    snprintf(many + used, sizeof many - used, "]}");
    assert(!parse(many));
    assert(parse("{\"items\":[{\"id\":\"1\",\"app\":\"应用\",\"title\":\"标题\"}],\"task\":\"unknown\"}"));
    int items = ap_json_get(&document, 0, "items");
    assert(ap_json_at(&document, items, 0) >= 0);
    assert(ap_json_at(&document, items, 1) == -1);
    assert(ap_json_get(&document, ap_json_get(&document, 0, "task"), "anything") == -1);
    puts("JSON security edge cases passed");
}
