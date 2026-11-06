#!/bin/bash
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
exec /bin/bash "$source_dir/start.sh"
