#!/usr/bin/env python3
"""Check the Arty S7 blink-echo image: the banner after configuration, then an
exact echo of every byte value and a random stream. Pass --program CMD to load
the board while listening, so the banner is caught."""
import os, random, select, subprocess, sys, termios, time

PORT = '/dev/cu.usbserial-210352B840A31'


def open_port():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[4] = a[5] = termios.B115200
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[0] = a[1] = a[3] = 0
    a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def read_for(fd, seconds, want=None):
    data = b''
    end = time.time() + seconds
    while time.time() < end and (want is None or len(data) < want):
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: data += os.read(fd, 65536)
            except BlockingIOError: pass
    return data


def read_for_line(fd, seconds):
    data = b''
    end = time.time() + seconds
    while time.time() < end and b'\r\n' not in data:
        data += read_for(fd, 0.05)
    return data


def main():
    fd = open_port()
    termios.tcflush(fd, termios.TCIOFLUSH)
    ok = True
    if len(sys.argv) > 2 and sys.argv[1] == '--program':
        subprocess.run(sys.argv[2:], check=True, capture_output=True)
        # SRAM loads appear within a second; a flash boot at the default
        # single-bit SPI clock takes several seconds.
        start = time.time()
        banner = read_for_line(fd, float(os.environ.get('BANNER_WAIT', '2')))
        print(f'banner after {time.time() - start:.1f} s')
        print('banner:', repr(banner))
        ok &= b'ARTY S7 ECHO READY\r\n' in banner
    termios.tcflush(fd, termios.TCIFLUSH)
    payload = bytes(range(256)) + bytes(random.Random(7).randrange(256) for _ in range(1744))
    got = b''
    for i in range(0, len(payload), 64):   # 64-byte chunks: the echo buffers one byte
        chunk = payload[i:i + 64]
        os.write(fd, chunk)
        got += read_for(fd, 1.0, want=len(chunk))
    mismatches = sum(1 for a, b in zip(payload, got) if a != b) + abs(len(payload) - len(got))
    print(f'echo: sent {len(payload)} bytes, received {len(got)}, mismatches {mismatches}')
    ok &= mismatches == 0
    os.close(fd)
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
