#include "rtsp_state_parser.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STATE_STR_LEN 12

typedef struct {
    const char *input_path;
    rtsp_trim_mode_t trim_mode;
    int json_output;
} cli_options_t;

static void *xmalloc(size_t size) {
    void *ptr = malloc(size);
    if (ptr == NULL) {
        fprintf(stderr, "rtsp_state_parser: malloc(%zu) failed\n", size);
        exit(1);
    }
    return ptr;
}

static void *xcalloc(size_t nmemb, size_t size) {
    void *ptr = calloc(nmemb, size);
    if (ptr == NULL) {
        fprintf(stderr, "rtsp_state_parser: calloc(%zu, %zu) failed\n", nmemb, size);
        exit(1);
    }
    return ptr;
}

static void *xrealloc(void *ptr, size_t size) {
    void *resized = realloc(ptr, size);
    if (resized == NULL) {
        fprintf(stderr, "rtsp_state_parser: realloc(%zu) failed\n", size);
        exit(1);
    }
    return resized;
}

static int append_state(rtsp_state_sequence_t *sequence, unsigned int value) {
    unsigned int *items = (unsigned int *)xrealloc(
        sequence->items, (sequence->count + 1) * sizeof(unsigned int));
    sequence->items = items;
    sequence->items[sequence->count] = value;
    sequence->count += 1;
    return 0;
}

int rtsp_extract_response_codes(
    const unsigned char *buf,
    size_t buf_size,
    rtsp_state_sequence_t *out_sequence) {
    size_t byte_count = 0;
    size_t mem_count = 0;
    size_t mem_size = 1024;
    unsigned char terminator[2] = {0x0D, 0x0A};
    unsigned char rtsp[5] = {0x52, 0x54, 0x53, 0x50, 0x2F};
    unsigned char *mem;

    if (out_sequence == NULL) {
        return -1;
    }

    out_sequence->items = NULL;
    out_sequence->count = 0;
    mem = (unsigned char *)xcalloc(mem_size, sizeof(unsigned char));

    append_state(out_sequence, 0);

    while (byte_count < buf_size) {
        memcpy(&mem[mem_count], buf + byte_count, 1);
        byte_count += 1;

        if ((mem_count > 0) && (memcmp(&mem[mem_count - 1], terminator, 2) == 0)) {
            if ((mem_count >= 5) && (memcmp(mem, rtsp, 5) == 0)) {
                char temp[4];
                unsigned int message_code;

                if (mem_count < 12) {
                    mem_count = 0;
                    continue;
                }

                memcpy(temp, &mem[9], 3);
                temp[3] = 0;
                message_code = (unsigned int)atoi(temp);
                if (message_code == 0) {
                    break;
                }
                append_state(out_sequence, message_code);
                mem_count = 0;
            } else {
                mem_count = 0;
            }
        } else {
            mem_count += 1;
            if (mem_count == mem_size) {
                mem_size *= 2;
                mem = (unsigned char *)xrealloc(mem, mem_size);
            }
        }
    }

    free(mem);
    return 0;
}

void rtsp_free_state_sequence(rtsp_state_sequence_t *sequence) {
    if (sequence == NULL) {
        return;
    }
    free(sequence->items);
    sequence->items = NULL;
    sequence->count = 0;
}

int rtsp_trim_state_sequence(
    const rtsp_state_sequence_t *input,
    rtsp_trim_mode_t trim_mode,
    rtsp_state_sequence_t *output) {
    size_t index;

    if (input == NULL || output == NULL) {
        return -1;
    }

    output->items = NULL;
    output->count = 0;

    for (index = 0; index < input->count; index++) {
        unsigned int state = input->items[index];

        if (trim_mode == RTSP_TRIM_TRIPLE && output->count >= 2) {
            if (output->items[output->count - 1] == state &&
                output->items[output->count - 2] == state) {
                continue;
            }
        }

        if (trim_mode == RTSP_TRIM_CONSECUTIVE && output->count >= 1) {
            if (output->items[output->count - 1] == state) {
                continue;
            }
        }

        append_state(output, state);
    }

    return 0;
}

int rtsp_state_sequence_to_string(
    const rtsp_state_sequence_t *sequence,
    char **out_text) {
    size_t index;
    size_t len = 0;
    char *text = NULL;

    if (sequence == NULL || out_text == NULL) {
        return -1;
    }

    *out_text = NULL;

    for (index = 0; index < sequence->count; index++) {
        char str_state[STATE_STR_LEN];
        size_t part_len;

        if (index + 1 == sequence->count) {
            snprintf(str_state, sizeof(str_state), "%u", sequence->items[index]);
        } else {
            snprintf(str_state, sizeof(str_state), "%u-", sequence->items[index]);
        }

        part_len = strlen(str_state);
        text = (char *)xrealloc(text, len + part_len + 1);
        memcpy(text + len, str_state, part_len + 1);
        len += part_len;
    }

    if (text == NULL) {
        text = (char *)xcalloc(1, 1);
    }

    *out_text = text;
    return 0;
}

static int read_all(FILE *stream, unsigned char **out_buf, size_t *out_size) {
    size_t capacity = 4096;
    size_t length = 0;
    unsigned char *buffer = (unsigned char *)xmalloc(capacity);

    while (!feof(stream)) {
        size_t remaining = capacity - length;
        size_t bytes_read;

        if (remaining == 0) {
            capacity *= 2;
            buffer = (unsigned char *)xrealloc(buffer, capacity);
            remaining = capacity - length;
        }

        bytes_read = fread(buffer + length, 1, remaining, stream);
        length += bytes_read;

        if (bytes_read == 0) {
            break;
        }
    }

    if (ferror(stream)) {
        free(buffer);
        return -1;
    }

    *out_buf = buffer;
    *out_size = length;
    return 0;
}

static int parse_trim_mode(const char *value, rtsp_trim_mode_t *trim_mode) {
    if (strcmp(value, "none") == 0) {
        *trim_mode = RTSP_TRIM_NONE;
        return 0;
    }
    if (strcmp(value, "triple") == 0) {
        *trim_mode = RTSP_TRIM_TRIPLE;
        return 0;
    }
    if (strcmp(value, "consecutive") == 0) {
        *trim_mode = RTSP_TRIM_CONSECUTIVE;
        return 0;
    }
    return -1;
}

static int parse_args(int argc, char **argv, cli_options_t *options) {
    int index;

    options->input_path = "-";
    options->trim_mode = RTSP_TRIM_TRIPLE;
    options->json_output = 1;

    for (index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--format") == 0) {
            if (index + 1 >= argc) {
                return -1;
            }
            index += 1;
            if (strcmp(argv[index], "json") == 0) {
                options->json_output = 1;
            } else if (strcmp(argv[index], "text") == 0) {
                options->json_output = 0;
            } else {
                return -1;
            }
            continue;
        }
        if (strcmp(argv[index], "--trim") == 0) {
            if (index + 1 >= argc || parse_trim_mode(argv[index + 1], &options->trim_mode) != 0) {
                return -1;
            }
            index += 1;
            continue;
        }
        if (strcmp(argv[index], "--help") == 0 || strcmp(argv[index], "-h") == 0) {
            return 1;
        }
        options->input_path = argv[index];
    }

    return 0;
}

static void print_usage(FILE *stream) {
    fprintf(stream,
            "Usage: rtsp_state_parser [--format json|text] [--trim none|triple|consecutive] [FILE|-]\n");
}

static int print_json(const rtsp_state_sequence_t *raw, const rtsp_state_sequence_t *trimmed) {
    size_t index;
    char *text = NULL;

    if (rtsp_state_sequence_to_string(trimmed, &text) != 0) {
        return -1;
    }

    printf("{\"raw_states\":[");
    for (index = 0; index < raw->count; index++) {
        if (index > 0) {
            printf(",");
        }
        printf("%u", raw->items[index]);
    }
    printf("],\"states\":[");
    for (index = 0; index < trimmed->count; index++) {
        if (index > 0) {
            printf(",");
        }
        printf("%u", trimmed->items[index]);
    }
    printf("],\"sequence\":\"");
    for (index = 0; text[index] != '\0'; index++) {
        if (text[index] == '\\' || text[index] == '"') {
            putchar('\\');
        }
        putchar(text[index]);
    }
    printf("\"}\n");

    free(text);
    return 0;
}

int main(int argc, char **argv) {
    cli_options_t options;
    FILE *input = stdin;
    unsigned char *buffer = NULL;
    size_t buffer_size = 0;
    rtsp_state_sequence_t raw = {0};
    rtsp_state_sequence_t trimmed = {0};
    int parse_status;

    parse_status = parse_args(argc, argv, &options);
    if (parse_status == 1) {
        print_usage(stdout);
        return 0;
    }
    if (parse_status != 0) {
        print_usage(stderr);
        return 2;
    }

    if (strcmp(options.input_path, "-") != 0) {
        input = fopen(options.input_path, "rb");
        if (input == NULL) {
            fprintf(stderr, "rtsp_state_parser: failed to open %s: %s\n", options.input_path, strerror(errno));
            return 1;
        }
    }

    if (read_all(input, &buffer, &buffer_size) != 0) {
        fprintf(stderr, "rtsp_state_parser: failed to read input\n");
        if (input != stdin) {
            fclose(input);
        }
        return 1;
    }

    if (input != stdin) {
        fclose(input);
    }

    if (rtsp_extract_response_codes(buffer, buffer_size, &raw) != 0) {
        fprintf(stderr, "rtsp_state_parser: failed to extract RTSP states\n");
        free(buffer);
        return 1;
    }
    free(buffer);

    if (rtsp_trim_state_sequence(&raw, options.trim_mode, &trimmed) != 0) {
        fprintf(stderr, "rtsp_state_parser: failed to trim RTSP states\n");
        rtsp_free_state_sequence(&raw);
        return 1;
    }

    if (options.json_output) {
        if (print_json(&raw, &trimmed) != 0) {
            rtsp_free_state_sequence(&raw);
            rtsp_free_state_sequence(&trimmed);
            return 1;
        }
    } else {
        char *text = NULL;
        if (rtsp_state_sequence_to_string(&trimmed, &text) != 0) {
            rtsp_free_state_sequence(&raw);
            rtsp_free_state_sequence(&trimmed);
            return 1;
        }
        puts(text);
        free(text);
    }

    rtsp_free_state_sequence(&raw);
    rtsp_free_state_sequence(&trimmed);
    return 0;
}
