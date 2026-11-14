"""List bundle IDs and sizes from a Riot RMAN manifest.

Usage: python rman_bundles.py <manifest file> [count]
Prints "<BUNDLE_ID_HEX> <size_bytes>" lines, largest first.

The manifest body is zstd-compressed, so this needs zstd support:
Python 3.14+ (stdlib compression.zstd) or `pip install zstandard`.
Exit code 2 means zstd is not available.
"""
import struct
import sys


def zstd_decompress(data, size):
    try:
        from compression import zstd  # Python 3.14+
        return zstd.decompress(data)
    except ImportError:
        pass
    try:
        import zstandard
    except ImportError:
        sys.stderr.write("zstd not available: use Python 3.14+ or pip install zstandard\n")
        sys.exit(2)
    return zstandard.ZstdDecompressor().decompress(data, max_output_size=size)


class Table:
    """Minimal FlatBuffers table reader."""

    def __init__(self, buf, pos):
        self.buf, self.pos = buf, pos
        vt = pos - struct.unpack_from("<i", buf, pos)[0]
        vt_size = struct.unpack_from("<H", buf, vt)[0]
        self.fields = [struct.unpack_from("<H", buf, vt + 4 + 2 * i)[0] for i in range((vt_size - 4) // 2)]

    def _off(self, i):
        return self.fields[i] if i < len(self.fields) else 0

    def u64(self, i):
        o = self._off(i)
        return struct.unpack_from("<Q", self.buf, self.pos + o)[0] if o else 0

    def u32(self, i):
        o = self._off(i)
        return struct.unpack_from("<I", self.buf, self.pos + o)[0] if o else 0

    def tables(self, i):
        o = self._off(i)
        if not o:
            return []
        vec = self.pos + o + struct.unpack_from("<I", self.buf, self.pos + o)[0]
        n = struct.unpack_from("<I", self.buf, vec)[0]
        out = []
        for k in range(n):
            p = vec + 4 + 4 * k
            out.append(Table(self.buf, p + struct.unpack_from("<I", self.buf, p)[0]))
        return out


def main():
    path = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    data = open(path, "rb").read()
    magic, _maj, _min, _flags, off, csize, _mid, usize = struct.unpack_from("<4sBBHIIQI", data, 0)
    if magic != b"RMAN":
        sys.stderr.write("not an RMAN manifest\n")
        sys.exit(1)
    body = zstd_decompress(data[off:off + csize], usize)
    root = Table(body, struct.unpack_from("<I", body, 0)[0])
    bundles = []
    for b in root.tables(0):  # Manifest.bundles
        size = sum(c.u32(1) for c in b.tables(1))  # Bundle.chunks[].compressed_size
        bundles.append((size, b.u64(0)))
    bundles.sort(reverse=True)
    for size, bid in bundles[:count]:
        print(f"{bid:016X} {size}")


if __name__ == "__main__":
    main()
