#!/usr/bin/env bash
set -euo pipefail

git checkout main
git pull
git fetch upstream
git merge upstream/main
git push
