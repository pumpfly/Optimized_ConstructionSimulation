#!/bin/sh
printf '\033c\033]0;%s\a' AutomatedConstructionSim
base_path="$(dirname "$(realpath "$0")")"
"$base_path/AutomatedConstructionSim_test_version.x86_64" "$@"
