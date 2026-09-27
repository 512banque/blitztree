// In-memory flat tree adapter for UI benchmarks; no disk scan or user data.
#include "../app/bz.h"
BzScan *bz_fixture_create(uint32_t count, const uint32_t *parents,
                         const uint64_t *alloc, const uint8_t *flags,
                         const uint32_t *child_off, const uint32_t *children,
                         const uint32_t *name_off, const uint8_t *name_blob);
