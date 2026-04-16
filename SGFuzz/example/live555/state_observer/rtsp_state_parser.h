#ifndef RTSP_STATE_PARSER_H
#define RTSP_STATE_PARSER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned int *items;
    size_t count;
} rtsp_state_sequence_t;

typedef enum {
    RTSP_TRIM_NONE = 0,
    RTSP_TRIM_TRIPLE = 1,
    RTSP_TRIM_CONSECUTIVE = 2,
} rtsp_trim_mode_t;

int rtsp_extract_response_codes(
    const unsigned char *buf,
    size_t buf_size,
    rtsp_state_sequence_t *out_sequence);

void rtsp_free_state_sequence(rtsp_state_sequence_t *sequence);

int rtsp_trim_state_sequence(
    const rtsp_state_sequence_t *input,
    rtsp_trim_mode_t trim_mode,
    rtsp_state_sequence_t *output);

int rtsp_state_sequence_to_string(
    const rtsp_state_sequence_t *sequence,
    char **out_text);

#ifdef __cplusplus
}
#endif

#endif
