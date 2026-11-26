// The only engine SPI the bench touches beyond OfflineRenderer itself. Kept in one file so
// the bench can be rebuilt against an older engine revision (stub these two out) for A/B.
@_spi(Bench) import SpatialEngine

func applyBenchSwitches(_ engine: SpatialEngine) {
}

func skippedBlocks(_ r: OfflineRenderer) -> UInt64 { 0 }
