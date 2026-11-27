[![tests](https://github.com/cosmoblonde/ddev-remote-pull/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/cosmoblonde/ddev-remote-pull/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/cosmoblonde/ddev-remote-pull)](https://github.com/cosmoblonde/ddev-remote-pull/commits)
[![release](https://img.shields.io/github/v/release/cosmoblonde/ddev-remote-pull)](https://github.com/cosmoblonde/ddev-remote-pull/releases/latest)

# DDEV Remote Pull

* [Overview](#overview)
* [Installation](#installation)
* [Configuration](#configuration)
* [Pulling](#pulling)
* [Tables without rows](#tables-without-rows)
* [Files](#files)
* [After the import](#after-the-import)
* [Credentials](#credentials)
* [How it works](#how-it-works)
* [Tests](#tests)
* [Credits](#credits)

## Overview

Pulls the database and files of a project from its own server (live, stage, ...) into DDEV over SSH:

```bash
ddev pull live
```

- **Database:** `mysqldump` on the server, compressed transfer, checked before anything changes locally. Large or
  personal tables (logs, caches, sessions, version history) come as structure only, without rows.
- **Backup:** the local database is saved before the import.
- **Files:** `rsync` of the configured folders, incremental.
- **No credentials in the project:** the database credentials stay on the server, SSH uses your own keys.

It is a set of [DDEV providers](https://docs.ddev.com/en/stable/users/providers/), so the usual `ddev pull` options
work, and the `pre-import-db` / `post-import-db` hooks run as with `ddev import-db`. Every step runs on the host:
ssh sees your `~/.ssh/config`, your keys and your ssh-agent. Works for any project type (TYPO3, MODX, WordPress,
plain PHP); the configuration template has examples for TYPO3 and MODX.

## Installation

```bash
ddev add-on get cosmoblonde/ddev-remote-pull
```

The first install creates `.ddev/remote-pull/config` from `config.dist`. Fill in the sources, check them and commit
the `.ddev` directory:

```bash
ddev remote-pull check
```

Remove with `ddev add-on remove remote-pull`. The config stays in place.

## Configuration

`.ddev/remote-pull/config`, shell syntax, committed with the project:

```bash
SOURCES="live stage"

LIVE_SSH="deploy@live.example.com"
LIVE_PORT="222"
LIVE_DB="project_live"
LIVE_ROOT="/var/www/project/current"

STAGE_SSH="deploy@stage.example.com"
STAGE_DB="project_stage"
STAGE_ROOT="/var/www/project-stage/current"

EMPTY_TABLES="cache_* cf_* sys_log sys_history be_sessions fe_sessions"
FILES="public/fileadmin"
FILES_EXCLUDE="_processed_ _temp_"
```

Every setting can be given per source as `<SOURCE>_<NAME>` (`LIVE_EMPTY_TABLES`, `STAGE_FILES`, ...); a name without
prefix is the default for all sources.

| Setting | Meaning |
|---------|---------|
| `SOURCES` | sources with a provider; `live` and `stage` come with the add-on |
| `<SOURCE>_SSH` | `user@host` or a `Host` of `~/.ssh/config` |
| `<SOURCE>_PORT` | ssh port, empty for the default or `~/.ssh/config` |
| `SSH_KEY` | private key; empty: ssh-agent and `~/.ssh/config` decide |
| `<SOURCE>_DB` | database on the server |
| `<SOURCE>_MYSQL_DEFAULTS` | option file with the credentials on the server, default `~/.my.cnf` there |
| `<SOURCE>_ROOT` | project root on the server, base of `FILES` |
| `EMPTY_TABLES` | tables pulled as structure only, `*` matches any characters |
| `DUMP_OPTIONS` | additional `mysqldump` options, e.g. `--routines` |
| `DUMP_DIR` | dumps and backups, default `~/ddev-remote-pull/<project>`; nothing is deleted automatically |
| `BACKUP` | `1` (default) backs up the local database before the import |
| `FILES` | folders relative to the project root, the same on the server and locally |
| `FILES_EXCLUDE` | rsync exclude patterns |
| `FILES_DELETE` | `1` removes local files that are gone on the server, default `0` |

Personal settings go to `.ddev/remote-pull/config.local` (ignored by git), your own key also to `REMOTE_PULL_SSH_KEY`
in your shell profile.

More sources: copy `.ddev/providers/live.yaml` to e.g. `prod.yaml`, replace `live` by `prod`, remove the
`#ddev-generated` line and add `prod` to `SOURCES`.

## Pulling

```bash
ddev pull live                    # database and files (asks first)
ddev pull live --skip-files       # database only
ddev pull live --skip-db          # files only
ddev pull live --skip-import      # only download the dump, change nothing
ddev pull live -y                 # do not ask
```

For one run, `--environment="NAME=value,NAME=value"` overrides some settings. Values must not contain commas, list
entries are separated by spaces:

| Name | Effect |
|------|--------|
| `EMPTY_TABLES="<pattern> ..."` | replaces the configured list |
| `WITH_DATA="<pattern> ..."` | these tables with rows, although `EMPTY_TABLES` lists them |
| `ALL_DATA=1` | all tables with rows |
| `BACKUP=0` | no backup of the local database |
| `DRY_RUN=1` | files: show what rsync would change, change nothing |
| `FILES_DELETE=1` | files: remove local files that are gone on the server |

```bash
ddev pull live --skip-files --environment="WITH_DATA=sys_history"
```

`ddev remote-pull` helps with the setup:

```bash
ddev remote-pull check            # ssh login, database and folders of every source
ddev remote-pull sizes live       # tables on live by size, structure-only ones marked
```

## Tables without rows

Logs, caches and version histories often make up most of a database, and nobody needs them locally. Tables matching
`EMPTY_TABLES` are dumped without rows in a second `mysqldump` pass, so the application still finds every table.
Patterns without a match are only noted, so one list serves several projects. `ddev remote-pull sizes <source>` shows
what is pulled with rows and what not, before anything is fetched.

Examples:

```bash
# TYPO3
EMPTY_TABLES="cache_* cf_* sys_log sys_history be_sessions fe_sessions"
# MODX
EMPTY_TABLES="modx_session modx_manager_log modx_versionx_* modx_seosuite_url"
```

Keep sessions out on purpose: they hold personal data.

## Files

`rsync` copies every folder of `FILES` from `<SOURCE>_ROOT/<folder>/` into the same folder of the project. Only
changed files are transferred. Local files that are gone on the server stay unless `FILES_DELETE=1`. A symlinked
folder on the server (shared folders of a release setup) is followed. rsync is needed on both sides; with GNU rsync
locally the overall progress is shown, the openrsync of macOS shows a summary.

## After the import

A dump from another environment brings its environment-specific settings along, for example base URLs or SMTP
settings that some systems keep in the database. Reset them in a `post-import-db` hook of the project, it runs after
`ddev pull` as after `ddev import-db`:

```yaml
# .ddev/config.yaml
hooks:
  post-import-db:
    - exec: mysql < /var/www/html/scripts/localize-db.sql   # e.g. MODX: site_url, mail settings, paths
    - exec: typo3 cache:flush                               # e.g. TYPO3
```

Do not search and replace the dump: that changes content as well.

## Credentials

- **Database:** `mysql` and `mysqldump` run on the server and read the credentials there, from `~/.my.cnf` of the
  server account (mode `600`) or from `<SOURCE>_MYSQL_DEFAULTS`. Keep `database=` out of the `[client]` section of
  that file: `mysqldump` reads it as a prefix of `--databases` and warns.
- **SSH:** the providers run without a terminal, so ssh cannot ask for a password or passphrase. Password and
  keyboard-interactive logins are switched off; a key with passphrase has to be in the ssh-agent (`ssh-add`, on
  macOS `ssh-add --apple-use-keychain`). With `SSH_KEY` only that key is offered.
- Nothing is written to the server.

Dumps contain whatever the database holds, personal data included. They stay in `DUMP_DIR`, outside the project, so
they end up neither in git nor in a Mutagen sync.

## How it works

`.ddev/providers/<source>.yaml` runs `.ddev/remote-pull/remote-pull <action> <source>` on the host:

1. `auth`: ssh login without prompt.
2. `db`: read the tables from `information_schema`, `mysqldump` with rows (except `EMPTY_TABLES`), `mysqldump
   --no-data` for the rest, `gzip` on the server. The dump goes to `DUMP_DIR` as `.part` and is renamed only when it
   is a valid gzip file and every `mysqldump` pass finished (`-- Dump completed`). `.ddev/.downloads/db.sql.gz`
   becomes a symlink to it.
3. `import`: back up the local database with `ddev export-db`, then `ddev import-db`. `ddev pull` runs the
   `pre-import-db` and `post-import-db` hooks around this step, the nested import skips its own.
4. `files`: `rsync` of every folder in `FILES`.

Runs with bash 3.2 (macOS) and newer.

## Tests

```bash
bats ./tests/test.bats --filter-tags '!release'
```

The tests need no server: `tests/testdata/bin/ssh` stands in for ssh and runs the commands locally, database commands
in the web container, so the project database plays the remote one.

## Credits

**Contributed and maintained by [cosmoblonde](https://github.com/cosmoblonde)**
