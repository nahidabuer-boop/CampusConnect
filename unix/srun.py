"""SRun account/password portal client shared by macOS and Linux."""

import base64
import hashlib
import hmac
import ipaddress
import json
import re
import struct
import time
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener

CALLBACK = 'campusConnect'
STANDARD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
CUSTOM = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA'
MASK = 0xFFFFFFFF


def _pack(text, append_length):
    encoded = text.encode('utf-16-le', 'surrogatepass')
    units = struct.unpack(f'<{len(encoded) // 2}H', encoded)
    words = [0] * ((len(units) + 3) // 4)
    for index, unit in enumerate(units):
        words[index // 4] |= (unit << ((index % 4) * 8)) & MASK
    if append_length:
        words.append(len(units))
    return words


def encode_info(info, token):
    words = _pack(json.dumps(info, ensure_ascii=False, separators=(',', ':')), True)
    key = _pack(token, False)
    key.extend([0] * max(0, 4 - len(key)))
    z = words[-1]
    total = 0
    for _ in range(6 + 52 // len(words)):
        total = (total + 0x9E3779B9) & MASK
        e = (total >> 2) & 3
        for position in range(len(words)):
            y = words[(position + 1) % len(words)]
            mix = (z >> 5) ^ (y << 2)
            mix += (y >> 3) ^ (z << 4) ^ (total ^ y)
            mix += key[(position & 3) ^ e] ^ z
            z = words[position] = (words[position] + mix) & MASK
    packed = struct.pack(f'<{len(words)}I', *words)
    return '{SRBX1}' + base64.b64encode(packed).decode('ascii').translate(str.maketrans(STANDARD, CUSTOM))


def login_params(username, password, ip, ac_id, token, platform):
    digest = hmac.new(token.encode(), password.encode(), 'md5').hexdigest()
    info = encode_info(dict(username=username, password=password, ip=ip, acid=ac_id, enc_ver='srun_bx1'), token)
    checksum = ''.join(token + field for field in (username, digest, ac_id, ip, '200', '1', info))
    return dict(action='login', username=username, password='{MD5}' + digest, ip=ip,
                ac_id=ac_id, info=info, chksum=hashlib.sha1(checksum.encode()).hexdigest(),
                n='200', type='1', double_stack='0', os=platform, name=platform, callback=CALLBACK)


def parse_response(body):
    wrapped = re.fullmatch(r'campusConnect\s*\((.*)\)\s*;?', body.strip(), re.S)
    result = json.loads(wrapped[1] if wrapped else body)
    if not isinstance(result, dict):
        raise ValueError('Invalid portal response')
    return result


def classify(body):
    body = body.strip()
    offline = {'not_online', 'not_online_error'}
    if body in offline:
        return 'offline'
    try:
        result = parse_response(body)
    except ValueError:
        fields = body.split(',')
        if len(fields) >= 10 and fields[0] and fields[1].isdigit():
            try:
                ipaddress.IPv4Address(fields[8])
                return 'online'
            except ValueError:
                pass
        return 'unknown'
    if result.get('error') in ('not_online', 'not_online_error') or result.get('res') == 'not_online_error':
        return 'offline'
    if result.get('error') == 'ok' and result.get('user_name') and result.get('online_ip'):
        return 'online'
    return 'unknown'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class Portal:
    def __init__(self, link):
        self.link = link.strip()
        parts = urlsplit(self.link)
        if (parts.scheme not in ('http', 'https') or not parts.hostname or
                parts.username is not None or parts.fragment or any(c.isspace() for c in self.link)):
            raise ValueError('请输入完整的 HTTP 或 HTTPS 校园网认证链接。')
        ac_ids = parse_qs(parts.query, keep_blank_values=True).get('ac_id', [])
        if len(ac_ids) != 1 or not re.fullmatch(r'[0-9]{1,8}', ac_ids[0]):
            raise ValueError('认证链接需要包含一个数字 ac_id，例如 ?ac_id=20。')
        self.ac_id = ac_ids[0]
        host = f'[{parts.hostname}]' if ':' in parts.hostname else parts.hostname
        port = parts.port
        authority = parts.netloc if parts.scheme == 'https' else host
        if port == 0:
            raise ValueError('认证链接的端口无效。')
        self.secure_origin = f'https://{authority}'
        self.secure_page = urlunsplit(('https', authority, parts.path, parts.query, ''))
        self.read_origin = f'{parts.scheme}://{parts.netloc}'
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def read(self, url, params=None):
        parts = urlsplit(url)
        suffix = urlencode({**(params or {}), '_': time.time_ns() // 1_000_000})
        query = f'{parts.query}&{suffix}' if parts.query else suffix
        target = urlunsplit(parts._replace(query=query))
        with self.opener.open(target, timeout=8) as response:
            return response.read(512 * 1024).decode('utf-8', 'replace')

    def status(self):
        for origin in dict.fromkeys((self.secure_origin, self.read_origin)):
            try:
                state = classify(self.read(origin + '/cgi-bin/rad_user_info', {'callback': CALLBACK}))
                if state != 'unknown':
                    return state
            except (OSError, ValueError):
                pass
        return 'unknown'

    def client_ip(self):
        for page in dict.fromkeys((self.secure_page, self.link)):
            try:
                match = re.search(r'''\bip\s*:\s*["']([0-9.]+)["']''', self.read(page))
                if match:
                    address = ipaddress.IPv4Address(match[1])
                    if not address.is_unspecified:
                        return str(address)
            except (OSError, ValueError):
                pass
        raise ValueError('未能从认证页面读取客户端 IP。')

    def reconnect(self, username, password, platform, should_login):
        stage = '读取认证页面'
        try:
            ip = self.client_ip()
            stage = '通过 HTTPS 获取挑战码'
            reply = self.read(self.secure_origin + '/cgi-bin/get_challenge',
                              dict(callback=CALLBACK, username=username, ip=ip))
            challenge = parse_response(reply)
            token = challenge.get('challenge')
            if challenge.get('error') != 'ok' or not isinstance(token, str) or not token:
                raise ValueError('No challenge')
            if self.status() != 'offline' or not should_login():
                return '认证状态已变化，等待下一次检查。', False
            stage = '通过 HTTPS 提交登录'
            params = login_params(username, password, ip, self.ac_id, token, platform)
            reply = parse_response(self.read(self.secure_origin + '/cgi-bin/srun_portal', params))
        except (OSError, ValueError):
            return f'{stage}失败，稍后重试。', False
        if reply.get('error') == 'ok':
            return '登录已受理，正在确认是否恢复在线。', False
        error = ' '.join(str(reply.get(key, '')) for key in ('error', 'error_msg', 'ecode'))
        if re.search(r'password|passwd|E2553', error, re.I):
            return '认证未通过，请核对账号和密码。', True
        return '学校未确认登录成功，稍后重试。', False
