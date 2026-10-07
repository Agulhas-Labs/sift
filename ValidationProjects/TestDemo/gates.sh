#!/bin/sh
# End-to-end gate for the TestDemo validation project. Takes a simulator destination UDID as $1,
# reuses it (never creates or deletes one), regenerates the Xcode project, and runs the checks
# sift's test-running features are validated against: the Default and Excluding plans green, the
# Retrying plan against the fail-once trigger, crash-unit, and fail-always.
#
# Never `cmd | tail; echo $?` — each command's exit code is captured directly into a variable, and
# its output goes to a log file under .gates-logs/ so a failure can be read back without re-running.
set -u

if [ "$#" -lt 1 ]; then
    echo "usage: gates.sh <simulator-udid>" >&2
    exit 2
fi

UDID="$1"
DESTINATION="platform=iOS Simulator,id=$UDID"

REPO="$(CDPATH= cd "$(dirname "$0")" && pwd)"
cd "$REPO"

LOGS="$REPO/.gates-logs"
mkdir -p "$LOGS"
TRIGGERS="$REPO/.triggers"

FAILED=0

# Every trigger this run sets is removed on exit, whatever happens in between.
cleanup() {
    rm -f "$TRIGGERS"/crash-unit "$TRIGGERS"/crash-ui "$TRIGGERS"/fail-once "$TRIGGERS"/fail-once.seen "$TRIGGERS"/fail-always "$TRIGGERS"/hang
}
trap cleanup EXIT

report() {
    NAME="$1"
    CODE="$2"
    EXPECT_ZERO="$3"
    if [ "$EXPECT_ZERO" = "zero" ]; then
        if [ "$CODE" -eq 0 ]; then
            echo "PASS $NAME"
        else
            echo "FAIL $NAME (exit $CODE, see $LOGS/$NAME.log)"
            FAILED=1
        fi
    else
        if [ "$CODE" -ne 0 ]; then
            echo "PASS $NAME"
        else
            echo "FAIL $NAME (expected non-zero, see $LOGS/$NAME.log)"
            FAILED=1
        fi
    fi
}

echo "==== xcodegen generate ===="
xcodegen generate > "$LOGS/generate.log" 2>&1
GENERATE_CODE=$?
report generate "$GENERATE_CODE" zero

if [ "$GENERATE_CODE" -ne 0 ]; then
    echo "generate failed, stopping"
    exit 1
fi

run_xcodebuild() {
    LOG_NAME="$1"
    shift
    xcodebuild test -project TestDemo.xcodeproj -scheme TestDemo -destination "$DESTINATION" \
        -derivedDataPath "$REPO/.derived" "$@" > "$LOGS/$LOG_NAME.log" 2>&1
    return $?
}

echo "==== Default plan ===="
run_xcodebuild default -testPlan Default
report default "$?" zero

echo "==== Excluding plan ===="
run_xcodebuild excluding -testPlan Excluding
report excluding "$?" zero

echo "==== Retrying plan + fail-once ===="
rm -f "$TRIGGERS/fail-once.seen"
touch "$TRIGGERS/fail-once"
run_xcodebuild retrying -testPlan Retrying -only-testing:DemoUnitTests
report retrying "$?" zero
rm -f "$TRIGGERS/fail-once" "$TRIGGERS/fail-once.seen"

echo "==== crash-unit ===="
touch "$TRIGGERS/crash-unit"
run_xcodebuild crash_unit -testPlan Default -only-testing:DemoUnitTests
report crash_unit "$?" nonzero
rm -f "$TRIGGERS/crash-unit"

echo "==== fail-always ===="
touch "$TRIGGERS/fail-always"
run_xcodebuild fail_always -testPlan Default -only-testing:DemoLogicTests
report fail_always "$?" nonzero
rm -f "$TRIGGERS/fail-always"

exit "$FAILED"
