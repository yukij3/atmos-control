// The C half of the AtmosCoreABI module: the header is the module; this file pins its layout
// at compile time (SwiftPM needs at least one source file in a C target anyway). The Rust
// declarations (crates/atmos-core-sys) check the same numbers in their tests.
#include "atmos_core.h"
#include <stddef.h>

_Static_assert(sizeof(AtmosOutputDevice) == ATMOS_CORE_OUTPUT_DEVICE_SIZE, "AtmosOutputDevice layout changed");
_Static_assert(sizeof(AtmosConfig) == ATMOS_CORE_CONFIG_SIZE, "AtmosConfig layout changed");
_Static_assert(sizeof(AtmosSnapshot) == ATMOS_CORE_SNAPSHOT_SIZE, "AtmosSnapshot layout changed");
_Static_assert(offsetof(AtmosSnapshot, outputs) == 44, "AtmosSnapshot.outputs moved");
_Static_assert(offsetof(AtmosSnapshot, config) == 4396, "AtmosSnapshot.config moved");
_Static_assert(offsetof(AtmosSnapshot, head_yaw) == 4536, "AtmosSnapshot.head_yaw moved");
_Static_assert(offsetof(AtmosSnapshot, last_error) == 5572, "AtmosSnapshot.last_error moved");
