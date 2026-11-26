/*
 * atmos_core.h — C ABI of libAtmosCore, the Swift engine + state model, for the Rust UI.
 *
 * libAtmosCore.dylib (SwiftPM product "AtmosCore") implements these functions with @_cdecl in
 * Sources/AtmosCore/AtmosCoreABI.swift. The Rust side declares the same items by hand in
 * crates/atmos-core-sys/src/lib.rs; its tests check the struct sizes and field offsets below
 * (ATMOS_CORE_SNAPSHOT_SIZE etc.), and so does atmos_core_abi.c at C compile time. Change
 * this header, the Swift implementation and the Rust declarations together, and bump
 * ATMOS_CORE_ABI_VERSION on any incompatible change.
 *
 * Threading contract
 *   - Every function must be called on the main thread (the thread running the NSApplication
 *     run loop; under Rune that is the UI thread). The Swift side traps otherwise
 *     (MainActor.assumeIsolated). The static functions (abi_version, default_config) are the
 *     only exceptions.
 *   - The state model finishes its asynchronous work (engine start/stop on a private serial
 *     queue, CoreAudio device and format listeners, CoreMotion, the 15 Hz meter timer) on the
 *     main dispatch queue, so the main run loop must be running for anything to change.
 *   - Commands never call back synchronously. When the state changes, the change callback
 *     runs once on a later main-queue turn (coalesced); the UI then reads a fresh snapshot.
 *
 * Lifetime: one AtmosCore per process (atmos_core_create). atmos_core_shutdown runs the
 * on-quit cleanup synchronously (stop the engine, destroy the process tap, restore the
 * system default output in the loopback modes) and must run before the process exits; after
 * it the handle stays valid but inert. The handle is never freed.
 */
#ifndef ATMOS_CORE_H
#define ATMOS_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ATMOS_CORE_ABI_VERSION 1u

/* ── Enumerations (uint32_t on the wire; values match SpatialEngine's raw values) ───────── */

/* Capture choice (CaptureChoice) */
#define ATMOS_CAPTURE_PERSONALIZED   0u /* process tap; headphones stay the system output */
#define ATMOS_CAPTURE_SURROUND       1u /* loopback driver, 12-channel 7.1.4 */
#define ATMOS_CAPTURE_VIRTUAL_STEREO 2u /* loopback driver, stereo */

/* Capture mode (EngineController.CaptureMode) */
#define ATMOS_CAPTURE_MODE_TAP      0u
#define ATMOS_CAPTURE_MODE_LOOPBACK 1u

/* OutputType */
#define ATMOS_OUTPUT_HEADPHONES 1u
#define ATMOS_OUTPUT_BUILT_IN   2u
#define ATMOS_OUTPUT_EXTERNAL   3u

/* HRTFMode */
#define ATMOS_HRTF_MODE_OFF  0u
#define ATMOS_HRTF_MODE_ON   1u
#define ATMOS_HRTF_MODE_AUTO 2u

/* SpatAlgorithm */
#define ATMOS_ALGORITHM_HRTF            2u
#define ATMOS_ALGORITHM_HRTF_HQ         6u
#define ATMOS_ALGORITHM_USE_OUTPUT_TYPE 7u /* "Automatic" */

/* SourceRenderMode */
#define ATMOS_SOURCE_DUAL_POINT_STEREO   0u
#define ATMOS_SOURCE_AMBIENCE_BED_STEREO 1u
#define ATMOS_SOURCE_POINT_SOURCE_MONO   2u
#define ATMOS_SOURCE_SURROUND_714        3u
#define ATMOS_SOURCE_SURROUND_BED_714    4u

/* AttenuationCurve */
#define ATMOS_CURVE_POWER       0u
#define ATMOS_CURVE_EXPONENTIAL 1u
#define ATMOS_CURVE_INVERSE     2u
#define ATMOS_CURVE_LINEAR      3u

/* ReverbRoomType */
#define ATMOS_ROOM_SMALL  0u
#define ATMOS_ROOM_MEDIUM 1u
#define ATMOS_ROOM_LARGE  2u

/* Engine status (the power switch's text pair) */
#define ATMOS_ENGINE_OFF      0u
#define ATMOS_ENGINE_STARTING 1u
#define ATMOS_ENGINE_ON       2u
#define ATMOS_ENGINE_STOPPING 3u

/* HRTF status */
#define ATMOS_HRTF_INACTIVE     0u /* engine off */
#define ATMOS_HRTF_PERSONALIZED 1u /* property 3116 = YES */
#define ATMOS_HRTF_GENERIC      2u /* see hrtf_detail for the reason */

/* Head-tracking status */
#define ATMOS_HEAD_TRACK_OFF         0u /* disabled in the config */
#define ATMOS_HEAD_TRACK_INACTIVE    1u /* enabled, engine off */
#define ATMOS_HEAD_TRACK_TRACKING    2u /* live pose */
#define ATMOS_HEAD_TRACK_UNAVAILABLE 3u /* running, no head-motion data */

/* Rebuild-class config fields for atmos_core_set_field. Values are numbers: enums as their
 * raw value, booleans as 0/1, distances in metres, gains in dB. */
#define ATMOS_FIELD_OUTPUT_TYPE          0u
#define ATMOS_FIELD_HRTF_MODE            1u
#define ATMOS_FIELD_ALGORITHM            2u
#define ATMOS_FIELD_SOURCE_MODE          3u
#define ATMOS_FIELD_HEAD_TRACKING        4u
#define ATMOS_FIELD_INTERAURAL_DELAY     5u
#define ATMOS_FIELD_DISTANCE_ATTENUATION 6u
#define ATMOS_FIELD_ATTENUATION_CURVE    7u
#define ATMOS_FIELD_DISTANCE_REF         8u
#define ATMOS_FIELD_DISTANCE_MAX         9u
#define ATMOS_FIELD_DISTANCE_MAX_ATTEN  10u
#define ATMOS_FIELD_REVERB_ENABLED      11u
#define ATMOS_FIELD_REVERB_ROOM_TYPE    12u
#define ATMOS_FIELD_GLOBAL_REVERB_GAIN  13u

/* atmos_core_set_source mask bits: which of the live source values to set */
#define ATMOS_SOURCE_SET_AZIMUTH   (1u << 0)
#define ATMOS_SOURCE_SET_ELEVATION (1u << 1)
#define ATMOS_SOURCE_SET_DISTANCE  (1u << 2)
#define ATMOS_SOURCE_SET_GAIN      (1u << 3)
#define ATMOS_SOURCE_SET_WIDTH     (1u << 4)

/* ── Snapshot ──────────────────────────────────────────────────────────────────────────── */

/* String fields are NUL-terminated UTF-8, cut at a character boundary when longer than
 * their capacity. An empty string means "none" for the optional ones. */
#define ATMOS_NAME_CAP        128u
#define ATMOS_STATUS_CAP       32u
#define ATMOS_TEXT_CAP        256u
#define ATMOS_ERROR_CAP      1024u
#define ATMOS_MAX_OUTPUTS      32u
#define ATMOS_MAX_CHANNELS     12u

typedef struct AtmosOutputDevice {
    uint32_t id;      /* AudioDeviceID */
    bool is_airpods;
    char name[ATMOS_NAME_CAP];
} AtmosOutputDevice;

/* SpatialConfig, minus the debug-only `spatialize`. */
typedef struct AtmosConfig {
    uint32_t output_type;       /* ATMOS_OUTPUT_* */
    uint32_t hrtf_mode;         /* ATMOS_HRTF_MODE_* */
    uint32_t algorithm;         /* ATMOS_ALGORITHM_* */
    uint32_t source_mode;       /* ATMOS_SOURCE_* */
    uint32_t attenuation_curve; /* ATMOS_CURVE_* */
    uint32_t reverb_room_type;  /* ATMOS_ROOM_* */
    bool head_tracking;
    bool interaural_delay;
    bool distance_attenuation;
    bool reverb_enabled;
    float azimuth;            /* degrees, -180…180 */
    float elevation;          /* degrees, -90…90 */
    float distance;           /* metres, 0.35…6, clamped to distance_max */
    float gain;               /* dB, -40…12 */
    float stereo_width;       /* degrees, 0…90 (Stereo Points only) */
    float distance_ref;       /* metres */
    float distance_max;       /* metres */
    float distance_max_atten; /* dB */
    float reverb_blend;       /* percent, 0…100 */
    float global_reverb_gain; /* dB */
} AtmosConfig;

typedef struct AtmosSnapshot {
    /* Header. The caller sets struct_size = sizeof(AtmosSnapshot) before the call. */
    uint32_t struct_size;
    uint32_t abi_version;     /* out: ATMOS_CORE_ABI_VERSION */
    uint64_t generation;      /* out: changes whenever any field below may have changed */

    /* Lifecycle */
    bool is_on;
    bool busy;                /* a lifecycle operation (start, stop, rebuild) is in flight:
                                 disable restart-class controls (power, capture, output) */
    bool can_run;             /* the current capture choice can run (driver present) */
    bool permission_needed;   /* the tap start failed on audio-capture consent */
    uint32_t engine_status;   /* ATMOS_ENGINE_* */

    /* Capture and output */
    uint32_t capture_choice;  /* ATMOS_CAPTURE_* */
    uint32_t capture_mode;    /* ATMOS_CAPTURE_MODE_* */
    bool atmos_present;       /* the loopback HAL device exists */
    bool surround_driver_installed; /* ... with 12 channels */
    bool has_selected_output; /* false = follow the macOS default output */
    bool outputs_truncated;   /* more than ATMOS_MAX_OUTPUTS real outputs */
    uint32_t selected_output_id;
    uint32_t output_count;
    AtmosOutputDevice outputs[ATMOS_MAX_OUTPUTS];

    AtmosConfig config;

    /* Telemetry (changes only while a surface is visible, see atmos_core_set_visible) */
    bool personalized_hrtf_engaged; /* AUSpatialMixer property 3116 */
    bool head_pose_live;
    uint32_t channel_peak_count;    /* 0, or 12 in the surround modes */
    float meter_l, meter_r;         /* linear 0…1, smoothed (fast attack, slow release) */
    float peak_hold_l, peak_hold_r; /* linear 0…1 */
    float channel_peaks[ATMOS_MAX_CHANNELS]; /* Atmos_7_1_4 order: L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr */
    double head_yaw;                /* radians */
    uint64_t ring_fill, total_captured, total_played; /* debug counters */

    /* Derived (computed in Swift so every UI agrees) */
    uint32_t hrtf_status;           /* ATMOS_HRTF_* */
    uint32_t head_track_status;     /* ATMOS_HEAD_TRACK_* */
    bool hrtf_engaged;              /* accent treatment */
    bool head_track_active;
    bool soundstage_is_default;     /* Reset soundstage has nothing to do */
    bool rendering_is_default;      /* Reset rendering has nothing to do */

    /* Strings */
    char engine_status_text[ATMOS_STATUS_CAP];       /* "Off", "Starting…", "On", "Stopping…" */
    char output_name[ATMOS_NAME_CAP];                /* the device audio renders (or will) to */
    char hrtf_short[ATMOS_STATUS_CAP];               /* "Inactive", "Personalized", "Generic" */
    char hrtf_detail[ATMOS_TEXT_CAP];                /* the reason sentence */
    char head_track_status_text[ATMOS_STATUS_CAP];
    char personalization_disabled_reason[ATMOS_TEXT_CAP]; /* "" = the HRTF picker is enabled */
    char music_atmos_advisory[ATMOS_TEXT_CAP];       /* "" = none */
    char last_error[ATMOS_ERROR_CAP];                /* "" = none; errors only, never info */
} AtmosSnapshot;

/* Layout pins (aarch64/x86_64 macOS), checked by atmos_core_abi.c and the Rust tests. */
#define ATMOS_CORE_OUTPUT_DEVICE_SIZE 136u
#define ATMOS_CORE_CONFIG_SIZE 68u
#define ATMOS_CORE_SNAPSHOT_SIZE 6600u

/* ── Functions ─────────────────────────────────────────────────────────────────────────── */

typedef struct AtmosCore AtmosCore; /* opaque */
typedef void (*AtmosCallback)(void *context);

/* Static (any thread). */
uint32_t atmos_core_abi_version(void);
/* The engine's defaults (SpatialConfig()), the single source of truth for Reset and for the
 * default markers the UI shows. */
void atmos_core_default_config(AtmosConfig *out);

/* Lifecycle. create starts the device monitor; the engine itself starts on power_on. */
AtmosCore *atmos_core_create(void);
void atmos_core_shutdown(AtmosCore *core);

/* Change notification: `callback(context)` runs on the main thread, on a later main-queue
 * turn, at most once per turn, after any state change. NULL unregisters. */
void atmos_core_set_change_callback(AtmosCore *core, AtmosCallback callback, void *context);
/* SIGTERM: Swift ignores the default action and calls `callback(context)` on the main thread,
 * so the UI can quit through its normal path (which calls atmos_core_shutdown). NULL restores
 * the default action. */
void atmos_core_set_terminate_callback(AtmosCore *core, AtmosCallback callback, void *context);

/* Cheap change check: compare with the last snapshot's generation. */
uint64_t atmos_core_generation(AtmosCore *core);
/* Copy the whole state out. `out->struct_size` must equal sizeof(AtmosSnapshot); returns
 * false (and writes nothing else) on a size mismatch. */
bool atmos_core_snapshot(AtmosCore *core, AtmosSnapshot *out);

/* Which UI surfaces are on screen (shown and not fully covered). Meter polling (15 Hz) and
 * CoreMotion head pose (~25 Hz) run only while the engine is on and either is true. */
void atmos_core_set_visible(AtmosCore *core, bool panel, bool settings);

/* Power. Asynchronous: watch busy / engine_status. power_on clears last_error. */
void atmos_core_power_on(AtmosCore *core);
void atmos_core_power_off(AtmosCore *core);
void atmos_core_toggle(AtmosCore *core);
void atmos_core_retry_capture(AtmosCore *core);       /* after a permission failure */
void atmos_core_open_privacy_settings(AtmosCore *core); /* Privacy & Security ▸ audio capture */

/* Capture and output. Ignored while busy. set_capture_choice restarts the engine if it runs. */
void atmos_core_set_capture_choice(AtmosCore *core, uint32_t choice);
/* Loopback modes only: follow_default = true follows the macOS default output. */
void atmos_core_select_output(AtmosCore *core, bool follow_default, uint32_t device_id);
void atmos_core_refresh_devices(AtmosCore *core);

/* Rebuild-class config: set_field updates the state (the UI shows it at once) without
 * touching the engine; apply_config applies every pending field (a brief audio gap while it
 * rebuilds). During a slider drag call set_field per step and apply_config on release.
 * Edits made while busy are queued and applied when the operation lands. */
void atmos_core_set_field(AtmosCore *core, uint32_t field, double value);
void atmos_core_apply_config(AtmosCore *core);

/* Live (no rebuild). `mask` selects which values to set (ATMOS_SOURCE_SET_*). Distance is
 * clamped to 0.35…distance_max, as the engine does. */
void atmos_core_set_source(AtmosCore *core, uint32_t mask, float azimuth, float elevation,
                           float distance, float gain, float stereo_width);
void atmos_core_set_reverb_blend(AtmosCore *core, float percent);
/* Position, gain and stereo width back to the defaults. */
void atmos_core_reset_soundstage(AtmosCore *core);
/* Algorithm, distance model and reverb back to the defaults (applies the config). */
void atmos_core_reset_rendering(AtmosCore *core);

#ifdef __cplusplus
}
#endif

#endif /* ATMOS_CORE_H */
