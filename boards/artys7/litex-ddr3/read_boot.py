#!/usr/bin/env python3
"""Load a bitstream into the Arty S7 while listening on its UART at 115200,
and print what the LiteX BIOS says (banner, DDR3 calibration, memtest)."""
import os, select, subprocess, sys, termios, time
PORT = '/dev/cu.usbserial-210352B840A31'
fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[4] = a[5] = termios.B115200
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[0] = a[1] = a[3] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
termios.tcflush(fd, termios.TCIOFLUSH)
subprocess.run(sys.argv[2:], check=True, capture_output=True)
data, end = b'', time.time() + float(sys.argv[1])
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try: data += os.read(fd, 65536)
        except BlockingIOError: pass
    if b'litex>' in data: break
# Optional console commands after the prompt: COMMANDS="cmd1;cmd2", each
# given CMD_WAIT seconds (default 180) to return to the prompt.
for command in [c for c in os.environ.get('COMMANDS', '').split(';') if c]:
    os.write(fd, command.encode() + b'\r')
    mark, end = len(data), time.time() + float(os.environ.get('CMD_WAIT', '180'))
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: data += os.read(fd, 65536)
            except BlockingIOError: pass
        if data.count(b'litex>', mark) >= 1 and len(data) > mark + len(command) + 8: break
os.close(fd)
sys.stdout.write(data.decode('latin-1'))
