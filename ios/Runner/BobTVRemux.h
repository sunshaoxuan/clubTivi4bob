#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef struct BobTVRemux BobTVRemux;
BobTVRemux *bobtv_remux_start(const char *source, const char *token);
int bobtv_remux_port(BobTVRemux *session);
int bobtv_remux_running(BobTVRemux *session);
char *bobtv_remux_events(BobTVRemux *session);
void bobtv_remux_free_string(char *value);
void bobtv_remux_destroy(BobTVRemux *session);
int bobtv_has_pcm_filter(void);
#ifdef __cplusplus
}
#endif
