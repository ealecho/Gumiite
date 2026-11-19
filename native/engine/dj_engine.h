#pragma once

/* Dart FFI resolves these via dlsym on the main executable. They must stay
 * globally visible and must not be stripped from Release/TestFlight builds. */
#if defined(__GNUC__) || defined(__clang__)
#define DJ_FFI_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#else
#define DJ_FFI_EXPORT
#endif

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* DjEngine;

DJ_FFI_EXPORT DjEngine dj_create(void);
DJ_FFI_EXPORT void dj_destroy(DjEngine engine);

DJ_FFI_EXPORT int dj_start(DjEngine engine);
DJ_FFI_EXPORT void dj_stop(DjEngine engine);

/** Output mode: 0 = internal stereo (phone), 1 = external 4ch USB (deck A 1-2, B 3-4).
 *  Android: mode 1 stops Oboe; Java USB AudioTrack is the sink.
 *  iOS: mode 1 opens a 4-channel RemoteIO stream on the current USB route. */
DJ_FFI_EXPORT int dj_set_output_mode(DjEngine engine, int mode);
DJ_FFI_EXPORT int dj_get_output_mode(DjEngine engine);
DJ_FFI_EXPORT int dj_get_output_channels(DjEngine engine);

DJ_FFI_EXPORT int dj_load(DjEngine engine, int deck, const char* path);
DJ_FFI_EXPORT void dj_unload(DjEngine engine, int deck);

DJ_FFI_EXPORT void dj_play(DjEngine engine, int deck, int playing);
DJ_FFI_EXPORT void dj_seek(DjEngine engine, int deck, double seconds);
DJ_FFI_EXPORT void dj_set_cue(DjEngine engine, int deck);
DJ_FFI_EXPORT void dj_jump_cue(DjEngine engine, int deck);

DJ_FFI_EXPORT double dj_position(DjEngine engine, int deck);
DJ_FFI_EXPORT double dj_duration(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_playing(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_loaded(DjEngine engine, int deck);

DJ_FFI_EXPORT void dj_set_gain(DjEngine engine, int deck, float linear);
DJ_FFI_EXPORT void dj_set_eq(DjEngine engine, int deck, float low_db, float mid_db, float high_db);
DJ_FFI_EXPORT void dj_set_filter(DjEngine engine, int deck, float amount);
DJ_FFI_EXPORT void dj_set_fader(DjEngine engine, int deck, float linear);
DJ_FFI_EXPORT void dj_set_xfader(DjEngine engine, float x);
DJ_FFI_EXPORT void dj_set_master(DjEngine engine, float linear);
DJ_FFI_EXPORT void dj_set_rate(DjEngine engine, int deck, float rate);
DJ_FFI_EXPORT void dj_set_keylock(DjEngine engine, int deck, int enabled);

DJ_FFI_EXPORT float dj_get_bpm(DjEngine engine, int deck);
DJ_FFI_EXPORT int dj_get_key(DjEngine engine, int deck);
DJ_FFI_EXPORT float dj_get_beat_offset(DjEngine engine, int deck);
/** Grid confidence from analysis run at load (0..1, -1 unknown / loaded from cache). */
DJ_FFI_EXPORT float dj_get_grid_confidence(DjEngine engine, int deck);
/** Loaded track's loudness (95th pct of 50 ms RMS) and peak, dBFS; -100 if unknown. */
DJ_FFI_EXPORT void dj_get_level(DjEngine engine, int deck, float* loudness_db, float* peak_db);
DJ_FFI_EXPORT void dj_nudge_grid(DjEngine engine, int deck, float seconds);
/** Replace the deck's grid: BPM (ignored if <= 1) and first-downbeat offset (s). */
DJ_FFI_EXPORT void dj_set_grid(DjEngine engine, int deck, float bpm, float beat_offset);

DJ_FFI_EXPORT void dj_set_loop(DjEngine engine, int deck, int enabled, float bars);
/** Enable a loop starting at start_sec (a quantized loop-in), not the playhead. */
DJ_FFI_EXPORT void dj_set_loop_from(DjEngine engine, int deck, float bars, double start_sec);
DJ_FFI_EXPORT double dj_loop_start(DjEngine engine, int deck);
DJ_FFI_EXPORT double dj_loop_end(DjEngine engine, int deck);
DJ_FFI_EXPORT void dj_set_hotcue(DjEngine engine, int deck, int index, double seconds);
DJ_FFI_EXPORT void dj_jump_hotcue(DjEngine engine, int deck, int index);
DJ_FFI_EXPORT double dj_get_hotcue(DjEngine engine, int deck, int index);
DJ_FFI_EXPORT void dj_clear_hotcue(DjEngine engine, int deck, int index);
DJ_FFI_EXPORT void dj_beat_jump(DjEngine engine, int deck, int beats);

/** 3-band waveform: low/mid/high bytes (0..127) per column. overview=0: detail
 *  columns at dj_wave_bands_per_sec() per second; overview=1: fixed-count overview. */
DJ_FFI_EXPORT int dj_wave_bands_per_sec(void);
DJ_FFI_EXPORT int dj_wave_bands_columns(DjEngine engine, int deck, int overview);
DJ_FFI_EXPORT int dj_wave_bands_copy(DjEngine engine, int deck, int overview, uint8_t* out, int columns);

/** Decode a 60s prefix (22 kHz mono) + BPM/key/grid. Uses ID3 TBPM/TKEY when present. */
DJ_FFI_EXPORT int dj_analyze_file(const char* path, float* bpm, int* key, float* beat_offset,
                                  float* grid_confidence);

/** Length in seconds from the file header / decoder. Does not decode PCM. */
DJ_FFI_EXPORT double dj_file_duration(const char* path);

/** Load PCM and apply previously cached analysis (skips BPM/key). bpm<=0 runs a full analyze. */
DJ_FFI_EXPORT int dj_load_with_analysis(DjEngine engine, int deck, const char* path, float bpm, int key,
                                        float beat_offset);

/** Output underruns since the stream opened; -1 when unknown (USB mode, iOS). */
DJ_FFI_EXPORT int dj_xrun_count(DjEngine engine);

/** Null-terminated reason for the last failed dj_load / open, or "". */
DJ_FFI_EXPORT const char* dj_last_error(void);

#ifdef __cplusplus
}
#endif
