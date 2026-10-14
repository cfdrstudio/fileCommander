"""Packs PNGs into a .ico (PNG-compressed entries, supported by all current browsers/Windows)."""
import struct, sys

def main(out, pngs):
    data = [open(p, "rb").read() for p in pngs]
    sizes = [struct.unpack(">II", d[16:24]) for d in data]   # width, height from the IHDR chunk
    header = struct.pack("<HHH", 0, 1, len(data))
    offset = 6 + 16 * len(data)
    entries = b""
    for (w, h), d in zip(sizes, data):
        entries += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(d), offset)
        offset += len(d)
    with open(out, "wb") as f:
        f.write(header + entries + b"".join(data))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
