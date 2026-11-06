#!/bin/bash
set -eu
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"

case "$(uname -s)" in
    Darwin) app_dir="$HOME/Library/Application Support/CampusConnect" ;;
    Linux) app_dir="${XDG_DATA_HOME:-$HOME/.local/share}/CampusConnect" ;;
    *) printf '%s\n' '此启动脚本仅用于 macOS 和 Linux。'; exit 1 ;;
esac

python_command="${CAMPUSCONNECT_PYTHON:-python3}"
if ! "$python_command" -c 'import sys, tkinter; sys.exit(sys.version_info < (3, 10))'; then
    printf '%s\n' '请先安装 Python 3.10 或更新版本及 Tkinter。安装方式见 README。'
    exit 1
fi

umask 077
mkdir -p -- "$app_dir"
if [ ! -x "$app_dir/venv/bin/python" ]; then
    "$python_command" -m venv "$app_dir/venv"
fi
python="$app_dir/venv/bin/python"
if ! cmp -s -- "$source_dir/requirements.txt" "$app_dir/requirements-installed.txt" ||
   ! "$python" -c 'import keyring' 2>/dev/null; then
    printf '%s\n' '正在安装系统钥匙串依赖。首次启动需要互联网连接。'
    "$python" -m pip install --disable-pip-version-check -r "$source_dir/requirements.txt"
    cp -- "$source_dir/requirements.txt" "$app_dir/requirements-installed.txt"
fi

for file in campusconnect.py srun.py; do
    temp_file="$(mktemp "$app_dir/.source.XXXXXX")"
    cp -- "$source_dir/$file" "$temp_file"
    mv -f -- "$temp_file" "$app_dir/$file"
done
exec "$python" "$app_dir/campusconnect.py"
