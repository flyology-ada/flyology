#!/bin/sh
set -eu

cd /workspace
FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 FLYOLOGY_TEST_FAULTS=1 \
  ./scripts/prepare-rts.sh
./scripts/alr-development.sh exec -- env -u GPR_CONFIG gprbuild \
  --RTS=/workspace/build/rts --subdirs=behavioral -f -c -r -p -j0 \
  -P tests/runtime_smoke.gpr fault_injection_smoke.adb
./scripts/alr-development.sh exec -- env -u GPR_CONFIG gprbuild \
  --RTS=/workspace/build/rts --subdirs=behavioral -f -b -l -p -j0 \
  -P tests/runtime_smoke.gpr fault_injection_smoke.adb
./scripts/run-with-timeout.sh 90 \
  tests/bin/behavioral/fault_injection_smoke file-uring-cq-backpressure
