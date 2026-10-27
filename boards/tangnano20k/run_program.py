#!/usr/bin/env python3
"""Load a flat binary into SimpleRisc over its UART, run it, print its output.

  run_program.py IMAGE.bin [--input TEXT] [--port PORT] [--freq-mhz 96]
  run_program.py IMAGE.bin [--input TEXT] --frame OUT.hex   (no board: write
      the host byte stream for tb_program.v instead)

The host protocol is the boot ROM's: 'P', the word count (16-bit little
endian), the words (little endian), then 'R'.  The ROM loads the image at
0x80000000 and runs it there.  INPUT is sent after 'R'.  Output is printed
until the program ends and the ROM sends "DONE".

--ram-base 0x80000000 sends 'H' instead of 'R'.  Only the separate RV64 core
(rv64/), which still has a hardware loader, uses it; the RV32 images (BRAM and
SDRAM) always run at 0x80000000 through the boot ROM's 'R'.

The port is opened once and kept open: closing and reopening the BL616 bridge's
UART while the FPGA is sending wedges it until the board is replugged (see
README.md).  On the way out, Ctrl-C (0x03) stops a program that is still
running before the port is closed.
"""
import argparse, fcntl, os, select, struct, sys, termios, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rom_protocol

CLOCKS_PER_BIT = 868


def frame_bytes(image: bytes, text: bytes, ram_base: int = 0) -> bytes:
    if ram_base not in (0, 0x80000000):
        raise ValueError("RAM base must be 0 or 0x80000000 (RV64 core only)")
    image += b"\0" * (-len(image) % 4)
    count = len(image) // 4
    if count > 16384:
        sys.exit(f"image is {count} words; SimpleRisc's memory holds 16384")
    return b"P" + struct.pack("<H", count) + image + (b"H" if ram_base else b"R") + text


def open_port(port: str, baud: int) -> int:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = attrs[1] = attrs[3] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    if baud != 115200:
        fcntl.ioctl(fd, 0x80085402, struct.pack("L", baud))  # macOS IOSSIOSPEED
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def send_frame(fd: int, frame: bytes) -> None:
    """Drain partial nonblocking writes before starting the execution timeout."""
    pending = memoryview(frame)
    while pending:
        _, writable, _ = select.select([], [fd], [], 1)
        if not writable:
            continue
        try:
            pending = pending[os.write(fd, pending):]
        except BlockingIOError:
            pass
    termios.tcdrain(fd)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", nargs="?")
    parser.add_argument("--input", default="", help="text sent after the program starts (\\n allowed)")
    parser.add_argument("--port", default="/dev/cu.usbserial-20250303171", help="serial device path, or 'auto' for single-port discovery")
    parser.add_argument("--freq-mhz", type=float, default=96, help="core clock; baud = clock / 868")
    parser.add_argument("--ram-base", type=lambda x: int(x, 0), default=0, choices=(0, 0x80000000), help="0x80000000 sends 'H' for the separate RV64 core; RV32 images ignore it")
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--frame", help="write the host byte stream as hex, one byte per line, and exit")
    parser.add_argument("--identify", action="store_true", help="query board identity ('I') before uploading (or exit if no image is given)")
    parser.add_argument("--protocol", choices=("p", "u"), default="p", help="upload protocol: legacy 'p' (P+R) or CRC32/timeout 'u' (I+U+C+G)")
    parser.add_argument("--manifest", help="verify board identity against a preset build-manifest.json")
    args = parser.parse_args()

    if not args.identify and not args.image:
        parser.error("image is required unless --identify is given")

    raw_image = b""
    input_bytes = args.input.encode().decode("unicode_escape").encode("latin-1")
    frame = b""
    if args.image:
        with open(args.image, "rb") as f:
            raw_image = f.read()
        if args.frame or args.protocol == "p":
            frame = frame_bytes(raw_image, input_bytes, args.ram_base)
    if args.frame:
        with open(args.frame, "w") as f:
            f.write("".join(f"{b:02x}\n" for b in frame))
        print(f"{len(frame)} bytes -> {args.frame}")
        return

    port = rom_protocol.discover_port(args.port)
    baud = round(args.freq_mhz * 1e6 / CLOCKS_PER_BIT)
    fd = open_port(port, baud)
    try:
        output = b""
        if args.identify or args.manifest or args.protocol == "u":
            ident = rom_protocol.query_identity(fd, expected_mhz=args.freq_mhz)
            rom_protocol.check_compatibility(
                ident,
                expected_cpu_mhz=round(args.freq_mhz),
                image_bytes=len(raw_image) if args.image else None,
                required_caps="UICG" if args.protocol == "u" else "PR",
                manifest=args.manifest,
            )
            if args.identify and not args.image:
                print(ident.raw)
                return
        if args.protocol == "u":
            rom_protocol.upload_image_u(fd, raw_image, max_words=ident.max_bytes // 4, timeout=max(5.0, args.timeout))
            initial = rom_protocol.start_guarded(fd)
            if input_bytes:
                send_frame(fd, input_bytes)
            if initial:
                sys.stdout.write(initial.decode("latin-1"))
                sys.stdout.flush()
                output += initial
        else:
            send_frame(fd, frame)
        deadline = time.time() + args.timeout
        while not output.endswith(b"DONE") and time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                chunk = os.read(fd, 4096)
                sys.stdout.write(chunk.decode("latin-1"))
                sys.stdout.flush()
                output += chunk
        if not output.endswith(b"DONE"):
            print(f"\n[no DONE within {args.timeout} s; sending Ctrl-C]", file=sys.stderr)
            os.write(fd, b"\x03")
            termios.tcdrain(fd)
            time.sleep(0.2)
            sys.exit(1)
        print()
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
