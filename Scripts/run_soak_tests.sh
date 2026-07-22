#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIR:h}"
PASSES="${DEVBERTH_SOAK_PASSES:-4}"

cd "$REPOSITORY_ROOT"
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DevBerth.xcodeproj \
  -scheme DevBerth \
  -derivedDataPath /tmp/devberth-soak-derived \
  -destination 'platform=macOS' \
  -test-iterations "$PASSES" \
  -only-testing:DevBerthTests/PerformanceSoakTests \
  -only-testing:DevBerthTests/PerformanceBenchmarkTests \
  -only-testing:DevBerthTests/AppModelPerformanceTests \
  -only-testing:DevBerthTests/AdaptiveMonitoringTests \
  -only-testing:DevBerthTests/EventBatchingTests \
  -only-testing:DevBerthTests/SecurityAndLoggingTests \
  -only-testing:DevBerthTests/DockerTests \
  -only-testing:DevBerthIntegrationTests \
  -only-testing:DevBerthMCPTests/ControlPlaneAndProtocolTests \
  CODE_SIGNING_ALLOWED=NO \
  test
