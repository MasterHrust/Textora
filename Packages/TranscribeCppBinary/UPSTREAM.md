# CTranscribe binary provenance

- Upstream project: `handy-computer/transcribe.cpp`
- Version: `v0.1.3`
- Release asset: `TranscribeCpp.xcframework.zip`
- Release URL: `https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/TranscribeCpp.xcframework.zip`
- Upstream archive SHA-256: `b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd`
- Vendored macOS binary SHA-256: `9bb4ece5101e4efab3bc584e95a744c7c3ecc80295c463372b43b6d2232af8d5`
- Architectures: `arm64`, `x86_64`

The upstream archive stores the versioned macOS framework links as duplicate
directories. This copy contains the same signed universal binary and public C
headers, repackaged with canonical framework symlinks so Xcode and `codesign`
can process it without warnings.
