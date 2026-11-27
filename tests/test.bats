#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

# There is no server in the tests: tests/testdata/bin/ssh stands in for ssh. It runs the commands locally, database
# commands in the web container, so the project database "db" plays the remote database and a folder of the test
# directory the remote project root.

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=cosmoblonde/ddev-remote-pull

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true
  # dumps and backups of the tests stay in the test directory
  export DUMPS="${TESTDIR}/dumps"
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  run ddev remote-pull --help
  assert_success
  assert_output --partial "Usage: ddev remote-pull"

  assert_file_exist .ddev/providers/live.yaml
  assert_file_exist .ddev/providers/stage.yaml
  assert_file_exist .ddev/remote-pull/config
  run grep -c '#ddev-generated' .ddev/remote-pull/config
  assert_output "0"
}

# configuration of the source "live" for the ssh stand-in
write_config() {
  mkdir -p "${TESTDIR}/server/public/fileadmin/_processed_"
  echo "image" > "${TESTDIR}/server/public/fileadmin/image.txt"
  echo "thumb" > "${TESTDIR}/server/public/fileadmin/_processed_/thumb.txt"
  cat > .ddev/remote-pull/config <<EOF
# defaults
empty_tables = sys_log cache_* not_there_*
files = public/fileadmin
files_exclude = "_temp_"
dump_dir = ${DUMPS}

[live]
ssh = user@live.example.com
port = 2222
db = db
root = ${TESTDIR}/server
; the section beats the defaults
files_exclude = '_processed_'

[stage]
ssh =
EOF
}

fill_database() {
  run ddev mysql -e "CREATE TABLE keep (id INT PRIMARY KEY, name VARCHAR(20));
    INSERT INTO keep VALUES (1, 'kept'), (2, 'also kept');
    CREATE TABLE sys_log (id INT PRIMARY KEY, msg VARCHAR(20));
    INSERT INTO sys_log VALUES (1, 'a'), (2, 'b');
    CREATE TABLE cache_pages (id INT PRIMARY KEY);
    INSERT INTO cache_pages VALUES (1);"
  assert_success
}

rows() {
  ddev mysql -N -B -e "SELECT COUNT(*) FROM $1" | tail -1
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "guards stop before anything is changed" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  export PATH="${DIR}/tests/testdata/bin:${PATH}"

  # the fresh config has no ssh target
  run ddev pull live -y --skip-files
  assert_failure
  assert_output --partial "ssh is not set in [live]"

  write_config
  # a source without a section
  run ddev remote-pull check prod
  assert_failure
  assert_output --partial "no section [prod]"

  # a section without an ssh target
  run ddev remote-pull check stage
  assert_failure
  assert_output --partial "ssh is not set in [stage]"

  # config.local beats config; values end up in a remote command line
  printf '[live]\ndb = db; rm -rf /\n' > .ddev/remote-pull/config.local
  run ddev remote-pull check live
  assert_failure
  assert_output --partial "invalid db in [live]"
  rm .ddev/remote-pull/config.local

  # the parser names the line of a typo
  printf 'emty_tables = x\n' >> .ddev/remote-pull/config
  run ddev remote-pull check live
  assert_failure
  assert_output --partial 'unknown setting "emty_tables"'
  write_config
  printf 'no equals sign\n' >> .ddev/remote-pull/config
  run ddev remote-pull check live
  assert_failure
  assert_output --partial 'expected "key = value"'
  write_config
  printf 'dump_dir = /tmp\n' >> .ddev/remote-pull/config
  run ddev remote-pull check live
  assert_failure
  assert_output --partial "dump_dir belongs before the first section"

  # the config is read, not executed
  write_config
  printf '[live]\nroot = $(touch %s/executed)\n' "${TESTDIR}" >> .ddev/remote-pull/config
  run ddev remote-pull check live
  assert_failure
  assert_output --partial "invalid root in [live]"
  assert_file_not_exist "${TESTDIR}/executed"

  write_config
  run ddev remote-pull sources
  assert_success
  assert_output "live stage"
}

@test "check and sizes" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  export PATH="${DIR}/tests/testdata/bin:${PATH}"
  write_config
  fill_database

  run ddev remote-pull check live
  assert_success
  assert_output --partial "[OK]   ssh login"
  assert_output --partial "[OK]   database db readable"
  assert_output --partial "[OK]   ${TESTDIR}/server/public/fileadmin"

  run ddev remote-pull sizes live
  assert_success
  assert_output --regexp "sys_log +structure only"
  assert_output --regexp "cache_pages +structure only"
  assert_output --partial "note: empty_tables entry 'not_there_*' matches no table on live"
  refute_output --regexp "keep +structure only"
}

@test "pull database and files" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  export PATH="${DIR}/tests/testdata/bin:${PATH}"
  write_config
  fill_database
  # a hook proves that ddev pull runs post-import-db around the import of the add-on, exactly once
  cat > .ddev/config.hook.yaml <<'EOF'
hooks:
  post-import-db:
    - exec-host: echo hook >> .ddev/hook.log
EOF
  run ddev restart -y
  assert_success

  run ddev pull live -y
  assert_success
  assert_output --partial "structure only:"
  assert_output --partial "Backing up the local database"

  # rows of the emptied tables are gone, the tables are still there
  assert_equal "$(rows keep)" "2"
  assert_equal "$(rows sys_log)" "0"
  assert_equal "$(rows cache_pages)" "0"
  assert_equal "$(grep -c hook .ddev/hook.log)" "1"

  # dump and backup outside the project
  run bash -c "ls ${DUMPS}/live--*.sql.gz ${DUMPS}/local--*.sql.gz"
  assert_success

  # files: excluded folders stay on the server
  assert_file_exist public/fileadmin/image.txt
  assert_file_not_exist public/fileadmin/_processed_/thumb.txt
}

@test "options of one run" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  export PATH="${DIR}/tests/testdata/bin:${PATH}"
  write_config
  fill_database

  # WITH_DATA takes a table back, BACKUP=0 skips the backup
  run ddev pull live -y --skip-files --environment="WITH_DATA=sys_log,BACKUP=0"
  assert_success
  assert_output --partial "no backup of the local database"
  assert_equal "$(rows sys_log)" "2"
  assert_equal "$(rows cache_pages)" "0"

  # ALL_DATA=1 empties nothing: cache_pages gets a row again on the "server", which is this database
  run ddev mysql -e "INSERT INTO cache_pages VALUES (1)"
  assert_success
  run ddev pull live -y --skip-files --environment="ALL_DATA=1,BACKUP=0"
  assert_success
  assert_output --partial "structure only: none"
  assert_equal "$(rows cache_pages)" "1"

  # --skip-import only downloads: the dump stays outside the project, .ddev/.downloads gets a symlink to it
  run ddev pull live -y --skip-files --skip-import
  assert_success
  assert_equal "$(rows cache_pages)" "1"
  assert [ -L .ddev/.downloads/db.sql.gz ]
  run gzip -t .ddev/.downloads/db.sql.gz
  assert_success

  # files: DRY_RUN changes nothing, FILES_DELETE removes what is gone on the server
  run ddev pull live -y --skip-db --environment="DRY_RUN=1"
  assert_success
  assert_file_not_exist public/fileadmin/image.txt
  echo "local" > public/fileadmin/local-only.txt
  run ddev pull live -y --skip-db --environment="FILES_DELETE=1"
  assert_success
  assert_file_exist public/fileadmin/image.txt
  assert_file_not_exist public/fileadmin/local-only.txt
}
