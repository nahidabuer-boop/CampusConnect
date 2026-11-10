"""Desktop settings and background worker for CampusConnect on macOS and Linux."""

import argparse
import fcntl
import hashlib
import math
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from srun import Portal

MAC = sys.platform == 'darwin'
LABEL = 'io.github.nahidabuer-boop.campusconnect'
APP_DIR = (Path.home() / 'Library' / 'Application Support' / 'CampusConnect' if MAC else
           Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local' / 'share') / 'CampusConnect')
SETTINGS = APP_DIR / 'settings.json'
STATUS = APP_DIR / 'status.json'


def atomic_write(path, content):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temp_path = Path(temporary.name)
        try:
            temporary.write(content)
            temporary.close()
            temp_path.replace(path)
        finally:
            temp_path.unlink(missing_ok=True)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def write_json(path, data):
    atomic_write(path, json.dumps(data, ensure_ascii=False).encode('utf-8'))


def credential_store():
    if MAC:
        from keyring.backends.macOS import Keyring
    else:
        from keyring.backends.SecretService import Keyring
    return Keyring()


def credential_id(portal, account):
    value = f'{portal.secure_origin}\n{account}'
    return hashlib.sha256(value.encode()).hexdigest()


def monitor_command():
    return [sys.executable, str(APP_DIR / 'campusconnect.py'), '--monitor']


def autostart_file():
    if MAC:
        return Path.home() / 'Library' / 'LaunchAgents' / f'{LABEL}.plist'
    config_home = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
    return config_home / 'autostart' / f'{LABEL}.desktop'


def launchctl(*args):
    return subprocess.run(['/bin/launchctl', *args], capture_output=True, timeout=10, check=False)


def desktop_exec_arg(value):
    # Desktop entries parse escapes twice, then expand %-codes.
    value = value.replace('%', '%%')
    value = ''.join('\\' + char if char in '\\"`$' else char for char in value)
    return '"' + value.replace('\\', '\\\\') + '"'


def enable_autostart():
    target = autostart_file()
    command = monitor_command()
    if MAC:
        domain = f'gui/{os.getuid()}'
        agent = f'{domain}/{LABEL}'
        atomic_write(target, plistlib.dumps({
            'Label': LABEL, 'ProgramArguments': command, 'RunAtLoad': True,
            'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 15,
        }))
        if launchctl('print', agent).returncode == 0:
            return
        if launchctl('bootstrap', domain, str(target)).returncode != 0:
            raise RuntimeError('无法启动 macOS 登录项。请确认在当前用户的图形桌面运行，并检查系统设置中的后台项目权限。')
    else:
        line = ' '.join(desktop_exec_arg(part) for part in command)
        content = f'[Desktop Entry]\nType=Application\nName=CampusConnect\nExec={line}\nTerminal=false\n'
        atomic_write(target, content.encode('utf-8'))
        subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)


def disable_autostart():
    autostart_file().unlink(missing_ok=True)
    if MAC:
        launchctl('bootout', f'gui/{os.getuid()}/{LABEL}')


LAST_LOG_KEY = None


def report(state, detail, retry_in=0, result_code=''):
    global LAST_LOG_KEY
    key = (state, detail, result_code)
    if key != LAST_LOG_KEY:
        try:
            log = APP_DIR / 'monitor.log'
            if log.exists() and log.stat().st_size >= 1024 * 1024:
                log.replace(APP_DIR / 'monitor.log.old')
            with log.open('a', encoding='utf-8') as stream:
                stamp = time.strftime('%Y-%m-%dT%H:%M:%S%z')
                stream.write(f'{stamp} state={state}; {detail} result={result_code}; retryIn={retry_in}\n')
            LAST_LOG_KEY = key
        except OSError:
            pass
    display = f'{detail} 距下次重试约 {retry_in} 秒。' if retry_in else detail
    write_json(STATUS, {'state': state, 'detail': display, 'checked_at': time.time(),
                        'retry_in_seconds': retry_in, 'result_code': result_code, 'version': '0.2.1'})


def retry_delay(credential_rejected=False):
    return 900 if credential_rejected else 15


def run_monitor():
    APP_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (APP_DIR / 'monitor.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        watch_network()


def watch_network():
    previous = None
    portal = None
    failures = 0
    wait = 15
    retry_at = 0
    detail = ''
    while True:
        settings = read_json(SETTINGS)
        if not settings.get('enabled'):
            report('stopped', '后台连接已停止。')
            return
        profile = (settings['link'], settings['account'], settings['revision'])
        if profile != previous:
            portal = Portal(settings['link'])
            previous = profile
            failures, wait, retry_at = 0, 15, 0
            detail = ''
        state = portal.status()
        if state == 'online':
            failures, wait, retry_at = 0, 15, 0
            portal.result_code = ''
            detail = '认证正常，正在后台监测。'
        elif state == 'offline':
            failures += 1
            if failures == 1:
                detail = '检测到未认证，正在确认。'
            if failures >= 2 and time.monotonic() >= retry_at:
                current = read_json(SETTINGS)
                if current != settings:
                    continue
                report(state, '正在尝试自动登录。')
                try:
                    account = settings['account']
                    password = credential_store().get_password(LABEL, credential_id(portal, account))
                except Exception:
                    password = None
                if not password:
                    detail = '无法读取系统钥匙串，请解锁后重新保存凭据。'
                    wait = 15
                else:
                    detail, rejected = portal.reconnect(
                        account, password, 'Mac' if MAC else 'Linux', lambda: read_json(SETTINGS) == settings)
                    del password
                    wait = retry_delay(rejected)
                retry_at = time.monotonic() + wait
        else:
            failures = 0
            detail = '认证接口不可达或不兼容，请检查校园网和认证链接。'
        remaining = max(0, math.ceil(retry_at - time.monotonic())) if state == 'offline' else 0
        report(state, detail, remaining, portal.result_code)
        time.sleep(min(10, max(1, remaining)) if remaining else 10)


def run_ui():
    import tkinter as tk
    from tkinter import messagebox, ttk

    root = tk.Tk()
    root.title('CampusConnect 校园网自动连接')
    root.minsize(610, 310)
    panel = ttk.Frame(root, padding=22)
    panel.pack(fill='both', expand=True)
    panel.columnconfigure(1, weight=1)
    ttk.Label(panel, text='填写学校的 SRun 认证链接。确认掉线后，程序会自动登录。').grid(
        row=0, column=0, columnspan=2, sticky='w', pady=(0, 14))

    saved = read_json(SETTINGS)
    fields = [tk.StringVar(value=saved.get('link', '')), tk.StringVar(value=saved.get('account', '')), tk.StringVar()]
    for row, (label, variable) in enumerate(zip(('认证链接', '校园网账号', '校园网密码'), fields), 1):
        ttk.Label(panel, text=label).grid(row=row, column=0, sticky='w', padx=(0, 12), pady=5)
        entry = ttk.Entry(panel, textvariable=variable, show='•' if row == 3 else '')
        entry.grid(row=row, column=1, sticky='ew', pady=5)
    ttk.Label(panel, text='链接需要包含 ac_id。密码保存在系统钥匙串中。').grid(
        row=4, column=0, columnspan=2, sticky='w', pady=(7, 12))
    buttons = ttk.Frame(panel)
    buttons.grid(row=5, column=1, sticky='w')
    status_text = tk.StringVar(value='尚未启用后台连接。')
    ttk.Label(panel, textvariable=status_text, wraplength=555).grid(
        row=6, column=0, columnspan=2, sticky='w', pady=(14, 0))

    def save():
        try:
            portal = Portal(fields[0].get())
            account, password = fields[1].get().strip(), fields[2].get()
            if not account or not password:
                raise ValueError('请输入账号和密码。')
        except ValueError as error:
            messagebox.showerror('请检查填写内容', str(error), parent=root)
            return
        try:
            credential_store().set_password(LABEL, credential_id(portal, account), password)
        except Exception:
            messagebox.showerror('无法保存密码', '请确认系统钥匙串已解锁。Linux 需要可用的 Secret Service（例如 GNOME Keyring）。', parent=root)
            return
        old_settings = read_json(SETTINGS)
        try:
            write_json(SETTINGS, dict(link=portal.link, account=account, enabled=True, revision=time.time_ns()))
            try:
                enable_autostart()
            except Exception:
                write_json(SETTINGS, old_settings)
                if not old_settings.get('enabled'):
                    disable_autostart()
                raise
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            messagebox.showerror('无法启用后台连接', str(error), parent=root)
            return
        fields[2].set('')
        status_text.set('已保存并启用自启，正在等待后台检测。')

    def stop():
        try:
            settings = read_json(SETTINGS)
            settings['enabled'] = False
            write_json(SETTINGS, settings)
            disable_autostart()
        except (OSError, subprocess.SubprocessError) as error:
            messagebox.showerror('无法关闭自启', str(error), parent=root)
            return
        status_text.set('已关闭自启，后台将在本轮检测结束后停止。')

    def refresh():
        settings = read_json(SETTINGS)
        current = read_json(STATUS)
        checked = current.get('checked_at', 0)
        if not settings.get('enabled'):
            status_text.set('后台连接和自启已关闭。')
        elif checked < settings.get('revision', 0) / 1e9 or time.time() - checked > 120:
            status_text.set('自启已配置，等待后台检测结果。')
        else:
            stamp = time.strftime('%H:%M:%S', time.localtime(checked))
            status_text.set(f'{stamp}  {current.get("detail", "")}')
        root.after(4000, refresh)

    ttk.Button(buttons, text='保存并启用自启', command=save).pack(side='left', padx=(0, 10))
    ttk.Button(buttons, text='停止并关闭自启', command=stop).pack(side='left')
    root.after(500, refresh)
    root.mainloop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--monitor', action='store_true')
    parser.add_argument('--check-link')
    args = parser.parse_args()
    if args.check_link:
        print(Portal(args.check_link).status())
    elif args.monitor:
        run_monitor()
    else:
        run_ui()
