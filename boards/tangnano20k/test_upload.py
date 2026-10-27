#!/usr/bin/env python3
"""Unit tests for run_program.send_frame and rom_protocol ('I'/'U'/'C'/'G')."""
import unittest
from unittest.mock import patch

import rom_protocol
from rom_protocol import (
    BoardNotRespondingError,
    CompatibilityError,
    LegacyRomError,
    PortDiscoveryError,
    ProtocolError,
    UploadError,
    baud_for_mhz,
    check_compatibility,
    crc32_bytes,
    crc32_word,
    discover_port,
    frame_u,
    parse_identity,
    query_identity,
    start_guarded,
    upload_image_u,
)
from run_program import send_frame


class FakeRomTransport:
    """In-memory serial transport simulating ROM responses and baud rate changes."""

    def __init__(self, board_mhz=48, legacy=False, identity_line=None, unresponsive=False):
        self.board_mhz = board_mhz
        self.current_baud = baud_for_mhz(board_mhz)
        self.legacy = legacy
        self.unresponsive = unresponsive
        self.identity_line = identity_line or (
            b'SRID1 isa=rv32imc cpu=00000030 mem=00000030 ram=00800000 '
            b'max=00200000 cap=PMXQVHTUICG id=0123456789abcdef\n'
        )
        self.rx_queue = bytearray()
        self.tx_history = []
        self.baud_history = []
        self.upload_responses = []
        self.readback_responses = []
        self.guarded_response = b''
        self.interrupted_upload = False

    def _baud_matches(self) -> bool:
        return not self.unresponsive and self.current_baud == baud_for_mhz(self.board_mhz)

    def set_baud(self, baud: int) -> None:
        self.current_baud = baud
        self.baud_history.append(baud)
        self.rx_queue.clear()

    def write(self, data: bytes, timeout: float = 5.0) -> None:
        del timeout
        self.tx_history.append(bytes(data))
        if not self._baud_matches():
            return
        if data == b'\x03':
            return
        if data == b'I':
            if self.interrupted_upload:
                self.interrupted_upload = False
                self.rx_queue.extend(b'ERR TMO\n')
            elif not self.legacy:
                self.rx_queue.extend(self.identity_line)
        elif data == b'T':
            self.rx_queue.extend(b'DONE')
        elif data.startswith(b'U'):
            crc = int.from_bytes(data[-4:], 'little')
            self._last_crc = crc
            if self.upload_responses:
                self.rx_queue.extend(self.upload_responses.pop(0))
            else:
                self.rx_queue.extend(f'OK {crc:08x}\n'.encode('ascii'))
        elif data == b'C':
            if self.readback_responses:
                self.rx_queue.extend(self.readback_responses.pop(0))
            else:
                self.rx_queue.extend(f'{getattr(self, "_last_crc", 0):08x}\n'.encode('ascii'))
        elif data == b'G':
            self.rx_queue.extend(self.guarded_response)

    def read_until(self, predicate, timeout: float) -> bytes:
        del timeout
        out = bytes(self.rx_queue)
        self.rx_queue.clear()
        return out if (out and predicate(out)) or out else b''

    def drain(self, quiet_s: float = 0.05, max_s: float = 0.5) -> bytes:
        del quiet_s, max_s
        if self.interrupted_upload and self._baud_matches():
            self.interrupted_upload = False
            self.rx_queue.extend(b'ERR TMO\n')
        out = bytes(self.rx_queue)
        self.rx_queue.clear()
        return out


class UploadAndProtocolTests(unittest.TestCase):
    def test_partial_nonblocking_writes_and_backpressure(self):
        sent = bytearray()
        calls = 0
        payload = bytes(range(256)) * 256
        sizes = iter([3, None, 1, 4096])

        def write(fd, view):
            nonlocal calls
            calls += 1
            n = next(sizes, len(view))
            if n is None:
                raise BlockingIOError()
            n = min(n, len(view))
            sent.extend(view[:n])
            return n

        with patch('run_program.select.select', return_value=([], [123], [])), \
                patch('run_program.os.write', side_effect=write), \
                patch('run_program.termios.tcdrain') as drain:
            send_frame(123, payload)
            self.assertEqual(sent, payload)
            self.assertEqual(calls, 5)
            drain.assert_called_once_with(123)

    def test_crc32_and_frame_u_construction(self):
        data = b'\x13\x00\x00\x00\x73\x00\x10\x00'
        w0 = int.from_bytes(data[:4], 'little')
        w1 = int.from_bytes(data[4:], 'little')
        manual = (~crc32_word(crc32_word(0xFFFFFFFF, w0), w1)) & 0xFFFFFFFF
        self.assertEqual(manual, crc32_bytes(data))

        frame, count, pcrc = frame_u(b'\xaa\xbb\xcc', max_words=16)
        self.assertEqual(count, 1)
        self.assertEqual(frame[:5], b'USRU1')
        self.assertEqual(pcrc, crc32_bytes(b'\xaa\xbb\xcc\x00'))
        with self.assertRaises(ValueError):
            frame_u(b'')
        with self.assertRaises(ValueError):
            frame_u(b'\x00' * 20, max_words=4)

    def test_parse_identity_valid_and_malformed(self):
        line = (
            'SRID1 isa=rv32imc cpu=00000030 mem=00000030 ram=00800000 '
            'max=00200000 cap=PMXQVHTUICG id=0123456789abcdef\n'
        )
        ident = parse_identity(line)
        self.assertEqual(ident.protocol, 'SRID1')
        self.assertEqual(ident.isa, 'rv32imc')
        self.assertTrue(ident.compressed)
        self.assertEqual(ident.cpu_mhz, 48)
        self.assertEqual(ident.mem_mhz, 48)
        self.assertEqual(ident.ram_bytes, 8 * 1024 * 1024)
        self.assertEqual(ident.max_bytes, 2 * 1024 * 1024)
        self.assertEqual(ident.capabilities, 'PMXQVHTUICG')
        self.assertEqual(ident.build_id, '0123456789abcdef')

        with self.assertRaisesRegex(CompatibilityError, 'unsupported ROM identity protocol'):
            parse_identity(line.replace('SRID1', 'SRID2'))

        for bad in (
            '',
            'DONE',
            line.replace('isa=rv32imc', 'isa=rv64im'),
            line.replace('cpu=00000030', 'cpu=00000000'),
            line.replace('max=00200000', 'max=01000000'),
            line.replace('id=0123456789abcdef', 'id=1234'),
        ):
            with self.assertRaises(ProtocolError, msg=bad):
                parse_identity(bad)

    def test_compatibility_checks_and_manifest_validation(self):
        ident = parse_identity(
            'SRID1 isa=rv32imc cpu=00000030 mem=00000030 ram=00800000 '
            'max=00200000 cap=PMXQVHTUICG id=0123456789abcdef\n'
        )
        manifest = {
            'ready': True,
            'configuration': {'compressed': True, 'cpu_mhz': 48, 'memory_mhz': 48, 'ram_bytes': 8388608},
            'rom_identity': {
                'isa': 'rv32imc',
                'cpu_mhz': 48,
                'mem_mhz': 48,
                'ram_bytes': 8388608,
                'max_bytes': 2097152,
                'build_id': '0123456789abcdef',
            },
        }
        check_compatibility(ident, image_bytes=4096, manifest=manifest)

        with self.assertRaisesRegex(CompatibilityError, 'ready=true'):
            check_compatibility(ident, manifest={'ready': False})
        with self.assertRaisesRegex(CompatibilityError, 'ISA mismatch'):
            check_compatibility(ident, expected_isa='rv32im')
        with self.assertRaisesRegex(CompatibilityError, 'CPU clock mismatch'):
            check_compatibility(ident, expected_cpu_mhz=96)
        with self.assertRaisesRegex(CompatibilityError, 'memory clock mismatch'):
            check_compatibility(ident, expected_mem_mhz=72)
        with self.assertRaisesRegex(CompatibilityError, 'RAM size mismatch'):
            check_compatibility(ident, expected_ram_bytes=65536)
        with self.assertRaisesRegex(CompatibilityError, 'lacks required capabilities'):
            check_compatibility(ident, required_caps='UICGZ')
        with self.assertRaisesRegex(CompatibilityError, 'build_id mismatch'):
            check_compatibility(ident, expected_build_id='fedcba9876543210')
        with self.assertRaisesRegex(CompatibilityError, 'exceeding board loader limit'):
            check_compatibility(ident, image_bytes=ident.max_bytes + 4)

    def test_port_discovery_ambiguity_and_override(self):
        self.assertEqual(discover_port('/dev/cu.usbserial-explicit', candidates=[]), '/dev/cu.usbserial-explicit')
        self.assertEqual(discover_port('auto', candidates=['/dev/cu.usbserial-1']), '/dev/cu.usbserial-1')
        with self.assertRaisesRegex(PortDiscoveryError, 'no serial ports'):
            discover_port('auto', candidates=[])
        with self.assertRaisesRegex(PortDiscoveryError, 'multiple candidate serial ports'):
            discover_port('auto', candidates=['/dev/cu.usbserial-1', '/dev/cu.usbserial-2'])

    def test_query_identity_legacy_and_in_place_clock_discovery(self):
        # Interrupted upload recovery on same port
        t = FakeRomTransport(board_mhz=48)
        t.interrupted_upload = True
        ident = query_identity(t, expected_mhz=48)
        self.assertEqual(ident.cpu_mhz, 48)

        # Legacy ROM detection ('T' -> DONE, 'I' ignored)
        legacy_t = FakeRomTransport(board_mhz=48, legacy=True)
        with self.assertRaisesRegex(LegacyRomError, "ignored 'I'"):
            query_identity(legacy_t, expected_mhz=48)

        # Clock mismatch discovery: board is at 96 MHz, host queries at 48 MHz
        mismatch_t = FakeRomTransport(
            board_mhz=96,
            identity_line=(
                b'SRID1 isa=rv32im cpu=00000060 mem=00000060 ram=00010000 '
                b'max=0000ff00 cap=PMXQVHTUICG id=3e4f9e9bc49cc713\n'
            ),
        )
        mismatch_t.set_baud(baud_for_mhz(48))
        with self.assertRaisesRegex(CompatibilityError, 'responded at 96 MHz'):
            query_identity(mismatch_t, expected_mhz=48)
        self.assertEqual(mismatch_t.current_baud, baud_for_mhz(48))

        # Unresponsive board across all candidate clocks
        dead_t = FakeRomTransport(board_mhz=48, unresponsive=True)
        with self.assertRaises(BoardNotRespondingError):
            query_identity(dead_t, expected_mhz=48)

    def test_upload_image_u_retry_and_guarded_start(self):
        image = b'\x13\x05\x00\x00\x73\x00\x10\x00'
        _, _, expected_crc = frame_u(image)

        # Transient timeout on attempt 0 recovered on attempt 1
        t = FakeRomTransport(board_mhz=48)
        t.upload_responses = [b'ERR TMO\n', f'OK {expected_crc:08x}\n'.encode('ascii')]
        crc = upload_image_u(t, image, retries=1)
        self.assertEqual(crc, expected_crc)

        # Readback 'C' corruption on attempt 0 recovered on attempt 1
        t2 = FakeRomTransport(board_mhz=48)
        t2.readback_responses = [b'deadbeef\n', f'{expected_crc:08x}\n'.encode('ascii')]
        crc2 = upload_image_u(t2, image, retries=1)
        self.assertEqual(crc2, expected_crc)

        # Persistent CRC failure raises UploadError
        t3 = FakeRomTransport(board_mhz=48)
        t3.upload_responses = [b'ERR CRC\n', b'ERR CRC\n']
        with self.assertRaisesRegex(UploadError, 'ERR CRC'):
            upload_image_u(t3, image, retries=1)

        # Guarded run ('G') refuses ERR NOIMG and passes through normal guest output
        t4 = FakeRomTransport(board_mhz=48)
        t4.guarded_response = b'ERR NOIMG\n'
        with self.assertRaisesRegex(UploadError, 'ERR NOIMG'):
            start_guarded(t4)

        t5 = FakeRomTransport(board_mhz=48)
        t5.guarded_response = b'hello from guest\n'
        self.assertEqual(start_guarded(t5), b'hello from guest\n')


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(UploadAndProtocolTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print('PASS: complete 64 KiB image across partial writes, SRID1 identity, clock discovery, and SRU1 CRC32 upload recovery')
