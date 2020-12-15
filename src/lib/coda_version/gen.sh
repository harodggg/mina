#!/bin/sh
set -e

branch=$(git rev-parse --verify --abbrev-ref HEAD || echo "<none found>")
commit_id_short=$(git rev-parse --short=8 --verify HEAD)

CWD=$PWD

# we are nested 5 directories deep (_build/<context>/src/lib/coda_version)
cd ../../../../..
  if [ -n "$CODA_COMMIT_SHA1" ]; then
    # pull from env var if set
    id="$CODA_COMMIT_SHA1"
  else
    if [ ! -e .git ]; then echo 'Error: git repository not found'; exit 1; fi
    id=$(git rev-parse --verify HEAD)
    if [ -n "$(git diff --stat)" ]; then id="[DIRTY]$id"; fi
  fi
  commit_date=$(git show HEAD -s --format="%cI")
  cd src/lib/marlin
    marlin_commit_id=$(git rev-parse --verify HEAD)
    if [ -n "$(git diff --stat)" ]; then marlin_commit_id="[DIRTY]$id"; fi
    marlin_commit_id_short=$(git rev-parse --short=8 --verify HEAD)
    marlin_commit_date=$(git show HEAD -s --format="%cI")
  cd ../../..
cd $CWD

echo "let commit_id = \"$id\"" > "$1"
echo "let commit_id_short = \"$commit_id_short\"" >> "$1"
echo "let branch = \"$branch\"" >> "$1"
echo "let commit_date = \"$commit_date\"" >> "$1"

echo "let marlin_commit_id = \"$marlin_commit_id\"" >> "$1"
echo "let marlin_commit_id_short = \"$marlin_commit_id_short\"" >> "$1"
echo "let marlin_commit_date = \"$marlin_commit_date\"" >> "$1"
