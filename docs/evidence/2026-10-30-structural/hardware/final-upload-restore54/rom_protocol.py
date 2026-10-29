#!/usr/bin/env python3
"""SimpleRisc boot ROM identification ('I') and CRC32/timeout upload ('U'/'C'/'G') protocol."""
from __future__ import annotations

from dataclasses import dataclass
import fcntl
import glob
import json
import os
from pathlib import Path
import re
import select
import struct
import sys
import termios
import time
import zlib

SRID_VERSION = 'SRID1'
SRU1_MAGIC = 0x31555253  # Little-endian "SRU1"
DEFAULT_MAX_WORDS_SDRAM = 524288  # 2 MiB / 4
DEFAULT_MAX_WORDS_BRAM = 16320    # (64 KiB - 256 B) / 4
CANDIDATE_CLOCKS_MHZ = (48, 96, 72, 54, 66, 27)
IOSSIOSPEED = 0x80045402

_IDENTITY_RE = re.compile(
    r'^(?P<version>SRID\d+)\s+'
    r'isa=(?P<isa>[a-z0-9_]+)\s+'
    r'cpu=(?P<cpu>[0-9a-f]{8})\s+'
    r'mem=(?P<mem>[0-9a-f]{8})\s+'
    r'ram=(?P<ram>[0-9a-f]{8})\s+'
    r'max=(?P<max>[0-9a-f]{8})\s+'
    r'cap=(?P<cap>[A-Z0-9]+)\s+'
    r'id=(?P<id>[0-9a-f]{16})$'
)


class ProtocolError(RuntimeError):
    """Base error for SimpleRisc boot ROM protocol failures."""


class LegacyRomError(ProtocolError):
    """Raised when a board responds DONE to 'T' but does not implement 'I'."""


class BoardNotRespondingError(ProtocolError):
    """Raised when the board does not respond at expected or candidate baud rates."""


class CompatibilityError(ProtocolError):
    """Raised when the board's reported identity is incompatible with the guest or manifest."""


class UploadError(ProtocolError):
    """Raised when a 'U' framed upload, 'C' readback, or 'G' guarded start fails."""


class PortDiscoveryError(ProtocolError):
    """Raised when serial port auto-discovery finds zero or multiple candidate ports."""


@dataclass(frozen=True)
class RomIdentity:
    protocol: str
    isa: str
    cpu_mhz: int
    mem_mhz: int
    ram_bytes: int
    max_bytes: int
    capabilities: str
    build_id: str
    raw: str

    @property
    def compressed(self) -> bool:
        return self.isa == 'rv32imc'


def crc32_word(crc: int, word: int) -> int:
    """Bitwise IEEE 802.3 CRC-32 update over one 32-bit little-endian word."""
    crc = (crc ^ (word & 0xFFFFFFFF)) & 0xFFFFFFFF
    for _ in range(32):
        crc = ((crc >> 1) ^ (0xEDB88320 if (crc & 1) else 0)) & 0xFFFFFFFF
    return crc


def crc32_bytes(data: bytes) -> int:
    """IEEE 802.3 CRC-32 over a byte sequence (matches ROM crc32_word on 4-byte words)."""
    return zlib.crc32(data) & 0xFFFFFFFF


def pad_image(image: bytes) -> bytes:
    """Pad a binary image with trailing zero bytes to a 32-bit word boundary."""
    return image + b'\x00' * ((-len(image)) % 4)


def frame_u(image: bytes, max_words: int = DEFAULT_MAX_WORDS_SDRAM) -> tuple[bytes, int, int]:
    """Build a 'U' upload frame: ('U' + 'SRU1' + count + hcrc + words + pcrc, count, pcrc)."""
    padded = pad_image(image)
    count = len(padded) // 4
    if count == 0:
        raise ValueError('program image must not be empty')
    if count > max_words:
        raise ValueError(f'program is {count} words ({len(padded)} bytes); loader limit is {max_words} words ({max_words * 4} bytes)')
    header_body = struct.pack('<II', SRU1_MAGIC, count)
    header_crc = crc32_bytes(header_body)
    payload_crc = crc32_bytes(padded)
    frame = b'U' + header_body + struct.pack('<I', header_crc) + padded + struct.pack('<I', payload_crc)
    return frame, count, payload_crc


def parse_identity(text: str | bytes) -> RomIdentity:
    """Parse and validate a 'SRID1 ...' identity line from the boot ROM."""
    if isinstance(text, bytes):
        try:
            text = text.decode('ascii')
        except UnicodeDecodeError as exc:
            raise ProtocolError(f'non-ASCII bytes in ROM identity reply: {text!r}') from exc
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    srid_lines = [line for line in lines if line.startswith('SRID')]
    target = srid_lines[-1] if srid_lines else (lines[-1] if lines else '')
    if not target:
        raise ProtocolError('empty ROM identity reply')
    match = _IDENTITY_RE.match(target)
    if not match:
        if target.startswith('SRID') and not target.startswith(SRID_VERSION + ' '):
            version = target.split()[0]
            raise CompatibilityError(f'unsupported ROM identity protocol {version!r}; expected {SRID_VERSION!r}')
        raise ProtocolError(f'malformed ROM identity reply: {target!r}')
    version = match.group('version')
    if version != SRID_VERSION:
        raise CompatibilityError(f'unsupported ROM identity protocol {version!r}; expected {SRID_VERSION!r}')
    isa = match.group('isa')
    if isa not in ('rv32im', 'rv32imc'):
        raise ProtocolError(f'unsupported ISA {isa!r} in ROM identity reply: {target!r}')
    cpu_mhz = int(match.group('cpu'), 16)
    mem_mhz = int(match.group('mem'), 16)
    ram_bytes = int(match.group('ram'), 16)
    max_bytes = int(match.group('max'), 16)
    if cpu_mhz <= 0 or mem_mhz <= 0 or ram_bytes <= 0 or max_bytes <= 0 or max_bytes > ram_bytes:
        raise ProtocolError(f'invalid clock or memory bounds in ROM identity reply: {target!r}')
    return RomIdentity(
        protocol=version,
        isa=isa,
        cpu_mhz=cpu_mhz,
        mem_mhz=mem_mhz,
        ram_bytes=ram_bytes,
        max_bytes=max_bytes,
        capabilities=match.group('cap'),
        build_id=match.group('id'),
        raw=target,
    )


def load_manifest_expectations(manifest: dict | Path | str) -> dict:
    """Load expected board identity and configuration from a build-manifest.json."""
    if isinstance(manifest, (str, Path)):
        path = Path(manifest)
        if not path.is_file():
            raise CompatibilityError(f'build manifest does not exist: {path}')
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise CompatibilityError(f'unreadable build manifest {path}: {exc}') from exc
    else:
        data = manifest
    if not isinstance(data, dict) or data.get('ready') is not True:
        raise CompatibilityError('build manifest is not marked ready=true')
    config = data.get('configuration') or {}
    rom_id = data.get('rom_identity') or {}
    expected_isa = rom_id.get('isa') or ('rv32imc' if config.get('compressed') else 'rv32im' if 'compressed' in config else None)
    return {
        'expected_isa': expected_isa,
        'expected_cpu_mhz': rom_id.get('cpu_mhz', config.get('cpu_mhz')),
        'expected_mem_mhz': rom_id.get('mem_mhz', config.get('memory_mhz')),
        'expected_ram_bytes': rom_id.get('ram_bytes', config.get('ram_bytes')),
        'expected_max_bytes': rom_id.get('max_bytes'),
        'expected_build_id': rom_id.get('build_id'),
    }


def check_compatibility(
    identity: RomIdentity,
    *,
    expected_isa: str | None = None,
    compressed: bool | None = None,
    expected_cpu_mhz: int | None = None,
    expected_mem_mhz: int | None = None,
    expected_ram_bytes: int | None = None,
    expected_max_bytes: int | None = None,
    image_bytes: int | None = None,
    required_caps: str = 'UICG',
    expected_build_id: str | None = None,
    manifest: dict | Path | str | None = None,
) -> RomIdentity:
    """Verify that a parsed RomIdentity matches all expected hardware/manifest constraints."""
    if manifest is not None:
        m = load_manifest_expectations(manifest)
        if expected_isa is None:
            expected_isa = m['expected_isa']
        if expected_cpu_mhz is None:
            expected_cpu_mhz = m['expected_cpu_mhz']
        if expected_mem_mhz is None:
            expected_mem_mhz = m['expected_mem_mhz']
        if expected_ram_bytes is None:
            expected_ram_bytes = m['expected_ram_bytes']
        if expected_max_bytes is None:
            expected_max_bytes = m['expected_max_bytes']
        if expected_build_id is None:
            expected_build_id = m['expected_build_id']

    if identity.protocol != SRID_VERSION:
        raise CompatibilityError(f'unsupported ROM protocol {identity.protocol!r}; expected {SRID_VERSION!r}')

    if expected_isa is None and compressed is not None:
        expected_isa = 'rv32imc' if compressed else 'rv32im'
    if expected_isa is not None and identity.isa != expected_isa:
        raise CompatibilityError(f'board ISA mismatch: board reports {identity.isa}, expected {expected_isa}')

    if expected_cpu_mhz is not None and identity.cpu_mhz != int(expected_cpu_mhz):
        raise CompatibilityError(
            f'CPU clock mismatch: board reports {identity.cpu_mhz} MHz, expected {int(expected_cpu_mhz)} MHz'
        )
    if expected_mem_mhz is not None and identity.mem_mhz != int(expected_mem_mhz):
        raise CompatibilityError(
            f'memory clock mismatch: board reports {identity.mem_mhz} MHz, expected {int(expected_mem_mhz)} MHz'
        )
    if expected_ram_bytes is not None and identity.ram_bytes != int(expected_ram_bytes):
        raise CompatibilityError(
            f'RAM size mismatch: board reports {identity.ram_bytes} bytes, expected {int(expected_ram_bytes)} bytes'
        )
    if expected_max_bytes is not None and identity.max_bytes != int(expected_max_bytes):
        raise CompatibilityError(
            f'loader max image size mismatch: board reports {identity.max_bytes} bytes, expected {int(expected_max_bytes)} bytes'
        )
    if required_caps:
        missing = [c for c in required_caps if c not in identity.capabilities]
        if missing:
            raise CompatibilityError(
                f'board loader lacks required capabilities {"".join(missing)!r} (reported cap={identity.capabilities!r})'
            )
    if expected_build_id is not None and identity.build_id.lower() != expected_build_id.lower():
        raise CompatibilityError(
            f'bitstream build_id mismatch: board reports id={identity.build_id}, expected id={expected_build_id}'
        )
    if image_bytes is not None:
        padded_bytes = len(pad_image(b'\x00' * image_bytes)) if image_bytes > 0 else 0
        if padded_bytes <= 0:
            raise CompatibilityError('program image is empty (0 bytes)')
        if padded_bytes > identity.max_bytes:
            raise CompatibilityError(
                f'program image is {padded_bytes} bytes, exceeding board loader limit of {identity.max_bytes} bytes'
            )
    return identity


def discover_port(
    explicit_port: str | None = None,
    *,
    candidates: list[str] | None = None,
    pattern: str = '/dev/cu.usbserial-*',
) -> str:
    """Resolve the serial port path, refusing ambiguous multi-port discovery without --port."""
    if explicit_port and explicit_port != 'auto':
        return explicit_port
    found = sorted(candidates if candidates is not None else glob.glob(pattern))
    if not found:
        raise PortDiscoveryError(f'no serial ports matching {pattern!r} found; pass --port explicitly')
    if len(found) > 1:
        joined = ', '.join(found)
        raise PortDiscoveryError(
            f'multiple candidate serial ports found ({joined}); pass --port explicitly to avoid probing unrelated devices'
        )
    return found[0]


def baud_for_mhz(freq_mhz: float, bit_cycles: int = 868) -> int:
    """Return the UART baud rate corresponding to a CPU clock in MHz."""
    if freq_mhz <= 0:
        raise ValueError('frequency must be positive')
    return round(freq_mhz * 1e6 / bit_cycles)


def set_fd_baud(fd: int, baud: int) -> None:
    """Reconfigure UART baud rate in-place on an open file descriptor without closing it."""
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    fallback = getattr(termios, f'B{baud}', termios.B115200)
    attrs[4] = fallback
    attrs[5] = fallback
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    if sys.platform == 'darwin' and not hasattr(termios, f'B{baud}'):
        fcntl.ioctl(fd, IOSSIOSPEED, struct.pack('i', baud))
    termios.tcflush(fd, termios.TCIOFLUSH)


class FdTransport:
    """Non-closing serial transport over an open OS file descriptor."""

    def __init__(self, fd: int):
        self.fd = fd

    def write(self, data: bytes, timeout: float = 5.0) -> None:
        view = memoryview(data)
        deadline = time.monotonic() + timeout
        while view:
            remaining = max(0.0, deadline - time.monotonic())
            _, writable, _ = select.select([], [self.fd], [], remaining)
            if not writable:
                raise TimeoutError('serial write timeout')
            written = os.write(self.fd, view)
            view = view[written:]
        try:
            termios.tcdrain(self.fd)
        except termios.error:
            pass

    def read_until(self, predicate, timeout: float) -> bytes:
        buf = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            ready, _, _ = select.select([self.fd], [], [], min(0.02, remaining))
            if ready:
                chunk = os.read(self.fd, 4096)
                if chunk:
                    buf.extend(chunk)
                    if predicate(bytes(buf)):
                        break
        return bytes(buf)

    def drain(self, quiet_s: float = 0.05, max_s: float = 0.5) -> bytes:
        buf = bytearray()
        start = time.monotonic()
        last_rx = start
        while time.monotonic() - start < max_s:
            rem = max(0.0, quiet_s - (time.monotonic() - last_rx))
            if rem <= 0:
                break
            ready, _, _ = select.select([self.fd], [], [], min(0.02, rem))
            if ready:
                chunk = os.read(self.fd, 4096)
                if chunk:
                    buf.extend(chunk)
                    last_rx = time.monotonic()
        return bytes(buf)

    def set_baud(self, baud: int) -> None:
        set_fd_baud(self.fd, baud)


def _as_transport(io) -> FdTransport:
    return FdTransport(io) if isinstance(io, int) else io


def _probe_once(transport, probe_timeout: float, recovery_wait: float) -> tuple[str, bytes]:
    """Probe the ROM at the current baud rate; returns ('srid', line) | ('legacy', b'DONE') | ('none', raw)."""
    transport.write(b'\x03')
    if recovery_wait > 0:
        transport.drain(quiet_s=recovery_wait, max_s=max(recovery_wait * 3, 0.2))
    for _ in range(2):
        transport.write(b'I')
        reply = transport.read_until(lambda b: b'\n' in b, probe_timeout)
        if b'SRID' in reply and b'\n' in reply:
            return 'srid', reply
        if b'ERR' in reply:
            transport.drain(quiet_s=0.03, max_s=0.15)
            continue
        break
    if reply.strip():
        return 'malformed', reply
    transport.write(b'T')
    t_reply = transport.read_until(lambda b: b.endswith(b'DONE') or b'\n' in b, probe_timeout)
    if b'DONE' in t_reply:
        return 'legacy', t_reply
    return 'none', reply + t_reply


def query_identity(
    io,
    *,
    expected_mhz: float | None = None,
    candidate_mhz: tuple[int, ...] = CANDIDATE_CLOCKS_MHZ,
    probe_timeout: float = 0.15,
    recovery_wait: float = 0.12,
) -> RomIdentity:
    """Synchronize with the boot ROM and query its 'I' identity without closing the port."""
    transport = _as_transport(io)
    kind, raw = _probe_once(transport, probe_timeout, recovery_wait)
    if kind in ('srid', 'malformed'):
        return parse_identity(raw)
    if kind == 'legacy':
        raise LegacyRomError(
            "board responded 'DONE' to 'T' but ignored 'I'; flashed bitstream contains an older boot ROM without 'I'/'U'/'C'/'G'"
        )

    if expected_mhz is not None and hasattr(transport, 'set_baud'):
        expected_baud = baud_for_mhz(expected_mhz)
        for cand in candidate_mhz:
            if abs(cand - expected_mhz) < 1e-6:
                continue
            transport.set_baud(baud_for_mhz(cand))
            ckind, craw = _probe_once(transport, probe_timeout, recovery_wait)
            if ckind == 'srid':
                transport.set_baud(expected_baud)
                ident = parse_identity(craw)
                raise CompatibilityError(
                    f'UART clock mismatch: board did not respond at {expected_mhz:g} MHz, '
                    f'but responded at {cand} MHz with {ident.raw!r}'
                )
            if ckind == 'legacy':
                transport.set_baud(expected_baud)
                raise LegacyRomError(
                    f"UART clock and ROM mismatch: board did not respond at {expected_mhz:g} MHz, "
                    f"and responded 'DONE' to 'T' (legacy ROM without 'I') at {cand} MHz"
                )
        transport.set_baud(expected_baud)

    raise BoardNotRespondingError(
        'no response from boot ROM on UART (checked expected baud'
        + (f' {expected_mhz:g} MHz and candidates {list(candidate_mhz)}' if expected_mhz is not None else '')
        + ')'
    )


def upload_image_u(
    io,
    image: bytes,
    *,
    max_words: int = DEFAULT_MAX_WORDS_SDRAM,
    verify_readback: bool = True,
    retries: int = 1,
    timeout: float = 5.0,
    recovery_wait: float = 0.12,
) -> int:
    """Upload a program image via 'U' with header/payload CRC32 and optional 'C' readback check."""
    transport = _as_transport(io)
    frame, _, expected_crc = frame_u(image, max_words=max_words)
    expected_ok = f'OK {expected_crc:08x}'.encode('ascii')
    last_error = 'no response'

    for attempt in range(retries + 1):
        if attempt > 0:
            transport.write(b'\x03')
            transport.drain(quiet_s=recovery_wait, max_s=max(recovery_wait * 3, 0.3))
        transport.write(frame, timeout=max(timeout, 5.0))
        reply = transport.read_until(lambda b: b'\n' in b, timeout)
        lines = [ln.strip() for ln in reply.splitlines() if ln.strip()]
        line = lines[-1] if lines else b''
        if line == expected_ok:
            if verify_readback:
                transport.write(b'C')
                c_reply = transport.read_until(lambda b: b'\n' in b, timeout)
                c_lines = [ln.strip() for ln in c_reply.splitlines() if ln.strip()]
                c_line = c_lines[-1] if c_lines else b''
                if c_line != f'{expected_crc:08x}'.encode('ascii'):
                    last_error = f"readback 'C' CRC mismatch: got {c_line!r}, expected '{expected_crc:08x}'"
                    continue
            return expected_crc
        if line.startswith(b'OK '):
            last_error = f"upload CRC mismatch in ROM ack: got {line.decode('ascii', 'replace')!r}, expected {expected_ok.decode()!r}"
        elif line.startswith(b'ERR'):
            last_error = f"ROM rejected upload with {line.decode('ascii', 'replace')}"
        elif not reply:
            last_error = 'timed out waiting for ROM upload acknowledgement'
        else:
            last_error = f'unexpected ROM upload reply: {reply!r}'

    raise UploadError(last_error)


def start_guarded(io, *, check_window: float = 0.02) -> bytes:
    """Start the verified image with 'G' and ensure the ROM did not reply 'ERR NOIMG'."""
    transport = _as_transport(io)
    transport.write(b'G')
    if check_window <= 0:
        return b''
    initial = transport.read_until(lambda b: b.startswith(b'ERR') and b'\n' in b, check_window)
    if initial.startswith(b'ERR NOIMG'):
        raise UploadError("ROM refused guarded execution ('G'): ERR NOIMG")
    return initial
