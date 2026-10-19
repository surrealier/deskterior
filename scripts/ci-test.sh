#!/usr/bin/env bash
# The full test run, in two groups: CI and the release workflow run it step by step, `make test` all at once.
# Portable to macOS's bash 3.2.
#
#   scripts/ci-test.sh build     builds the package and its tests (scripts/swift-test.sh --build-only)
#   scripts/ci-test.sh serial    DeskteriorAppTests, one test at a time (--no-parallel): app sessions, windows and
#                                editors that wait on real debounces, timers and hops through the main queue. Run with
#                                the rest, hundreds of main-actor tests start at once and queue on the one main actor, so
#                                a test waits minutes at every await; alone, it waits only on its own work.
#   scripts/ci-test.sh parallel  every other test target (DeskCore, DeskFiles, DeskPixels, DeskScene, and any new one),
#                                in parallel: their main-actor tests are synchronous and wait on no clock there.
#   scripts/ci-test.sh           all three in that order; both groups run even if the first one fails.
# Extra arguments go to `swift test` for serial and parallel (CI passes --skip-build after its build step), and to
# every step without a group; a rerun takes none of them.
#
# A group that fails reruns only its failed tests, once, one at a time (`--skip-build --no-parallel`, read from the
# group's xUnit file). One that passes then is a flake: the step passes, with a ::warning annotation naming it and a
# line in the job summary, so it stays visible. One that fails again fails the step. A run that failed without naming
# a failed test (a crash or a hang: no xUnit file, or no failure in it), or with more than CI_TEST_MAX_RETRY of them
# (default 5: that is a regression, not a flake), is not rerun. CI_TEST_RETRY=0 turns the rerun off.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

serialTargets='^DeskteriorAppTests\.'

if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
  scripts/ci-test.sh build "$@"
  rc=0
  scripts/ci-test.sh serial --skip-build "$@" || rc=1
  scripts/ci-test.sh parallel --skip-build "$@" || rc=1
  exit "$rc"
fi
group="$1"
shift
case "$group" in
  build) exec scripts/swift-test.sh --build-only "$@" ;;
  serial) select=(--filter "$serialTargets" --no-parallel) ;;
  parallel) select=(--skip "$serialTargets") ;;
  *) echo "usage: scripts/ci-test.sh [build|serial|parallel] [swift test options]" >&2; exit 2 ;;
esac
out=".build/ci-test/$group"
rm -rf "$out"
mkdir -p "$out"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

rc=0
scripts/swift-test.sh "${select[@]}" --xunit-output "$out/run.xml" "$@" || rc=$?
[ "$rc" -eq 0 ] && exit 0

# The xUnit file swift-testing wrote (with "-swift-testing" before the extension when XCTest also runs).
xunit() { if [ -f "$1.xml" ]; then echo "$1.xml"; else echo "$1-swift-testing.xml"; fi; }

# Failed tests as swift-testing ids, from the xUnit classname ("Module", "Module.Suite", "Module.Outer.Inner") and
# name: "Module.name()" (a free function), "Module.Suite/name()", "Module.Outer/Inner/name()".
failed() {
  [ -f "$1" ] || return 0
  perl -ne '
    if (/<testcase classname="([^"]*)" name="([^"]*)"/) { ($c, $n) = ($1, $2); }
    if (/<(failure|error)\b/ && defined $c) {
      ($m, $suite) = split(/\./, $c, 2);
      $id = defined $suite ? "$m." . ($suite =~ s/\./\//gr) . "/$n" : "$m.$n";
      $id =~ s/&lt;/</g; $id =~ s/&gt;/>/g; $id =~ s/&quot;/"/g; $id =~ s/&apos;/\x27/g; $id =~ s/&amp;/&/g;
      print "$id\n" unless $seen{$id}++;
    }' "$1"
}
ids="$(failed "$(xunit "$out/run")")"
count=0
[ -n "$ids" ] && count="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  echo "::error title=$group tests::swift test failed ($rc) without naming a failed test (a crash or a hang); not rerun"
  exit "$rc"
fi
if [ "${CI_TEST_RETRY:-1}" = 0 ] || [ "$count" -gt "${CI_TEST_MAX_RETRY:-5}" ]; then
  printf '%s\n' "$ids" | while IFS= read -r id; do echo "::error title=Test failed::$id"; done
  echo "$count $group tests failed; not rerun"
  exit "$rc"
fi

echo "::group::Rerunning $count failed $group test(s) once, one at a time"
filters=()
while IFS= read -r id; do
  # The whole id as a regex: a test's id may go on with "/File.swift:line:column", so it ends there or at "/".
  re="$(printf '%s' "$id" | perl -pe 's/([\\^\$.|?*+()\[\]{}])/\\$1/g')"
  filters+=(--filter "^$re(/|\$)")
done <<EOF
$ids
EOF
rc2=0
scripts/swift-test.sh --skip-build --no-parallel ${filters[@]+"${filters[@]}"} --xunit-output "$out/rerun.xml" || rc2=$?
echo "::endgroup::"

rerun="$(xunit "$out/rerun")"
ran="$(perl -ne 'print "$1\n" if /<testsuite [^>]*\btests="(\d+)"/' "$rerun" 2>/dev/null | head -1)"
if [ "${ran:-0}" -lt "$count" ]; then
  printf '%s\n' "$ids" | while IFS= read -r id; do echo "::error title=Test failed::$id"; done
  echo "::error title=$group tests::the rerun ran ${ran:-0} of the $count failed tests"
  exit 1
fi
again="$(failed "$rerun")"
status=0
while IFS= read -r id; do
  if printf '%s\n' "$again" | grep -Fxq -- "$id"; then
    echo "::error title=Test failed twice::$id failed, and failed again when rerun alone"
    echo "- failed twice: \`$id\`" >> "$summary"
    status=1
  else
    echo "::warning title=Flaky test::$id failed, then passed when rerun alone"
    echo "- flaky: \`$id\` failed, then passed when rerun alone" >> "$summary"
  fi
done <<EOF
$ids
EOF
[ "$rc2" -ne 0 ] && status=1
exit "$status"
