#!/usr/bin/env python3
"""mksd.py -- build a bootable Commander X16 FAT32 SD-card image.

    python tools/mksd.py <out.img> <file> [<file> ...] [--dir NAME <file> ...]

Creates a ~48 MB image: an MBR with one FAT32-LBA partition at LBA 2048,
a freshly formatted FAT32 volume, and each host file copied into the
root with its basename (uppercased, 8.3). The X16 boots it with
`x16emu -sdcard <out.img>`, running AUTOBOOT.X16 the same way -fsroot
does -- so the same build boots either way.

One level of SUBDIRECTORY is supported: everything after `--dir NAME`
goes into a directory of that name (repeat the flag for more). The
desktop shows it as a folder, so demos can live out of the root.

FAT32 layout only; no long names, one directory level. Enough to carry a
boot set (AUTOBOOT.X16, CXKERNEL.PRG, CXBANKS.BIN, PXL8.CXF, the CXAs).
The on-disk structures follow the FAT32 spec; the MBR/BPB constants match
what CMDR-DOS expects (partition at 2048, 0x0C type).
"""
import os
import struct
import sys

SECTOR = 512
PART_LBA = 2048                 # where the partition starts
SPC = 1                         # sectors per cluster (512 B clusters)
RSVD = 32                       # reserved sectors (FAT32 standard)
NFAT = 2
IMG_SECTORS = 40 * 1024 * 1024 // SECTOR   # 40 MB (>65525 clusters at SPC=1)


def build(out, files, subdirs=None):
    part_sectors = IMG_SECTORS - PART_LBA
    # size the FAT so every data cluster has an entry. Iterate: a bigger
    # FAT leaves fewer data sectors, so solve for a consistent split.
    fatsz = 1
    while True:
        data_sectors = part_sectors - RSVD - NFAT * fatsz
        clusters = data_sectors // SPC
        need = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        if need <= fatsz:
            break
        fatsz = need
    if clusters < 65525:
        sys.exit("image too small for FAT32 (need >= 65525 clusters)")

    img = bytearray(IMG_SECTORS * SECTOR)

    # ---- MBR: one partition, type 0x0C (FAT32 LBA) --------------------
    part = struct.pack(
        "<B3sB3sII",
        0x00,                    # not bootable (the ROM finds it anyway)
        b"\x00\x00\x00",         # CHS start, ignored for LBA
        0x0C,                    # FAT32 LBA
        b"\x00\x00\x00",         # CHS end
        PART_LBA,                # start LBA
        part_sectors,            # count
    )
    img[446:446 + 16] = part
    img[510:512] = b"\x55\xAA"

    base = PART_LBA * SECTOR
    fat_start = PART_LBA + RSVD
    data_start = fat_start + NFAT * fatsz
    root_clus = 2

    # ---- BPB / boot sector -------------------------------------------
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", bs, 11, SECTOR)      # bytes/sector
    bs[13] = SPC
    struct.pack_into("<H", bs, 14, RSVD)
    bs[16] = NFAT
    struct.pack_into("<H", bs, 17, 0)           # root entries (0 on FAT32)
    struct.pack_into("<H", bs, 19, 0)           # small sectors (0 -> use big)
    bs[21] = 0xF8                               # media
    struct.pack_into("<H", bs, 22, 0)           # sectors/FAT16 (0 on FAT32)
    struct.pack_into("<H", bs, 24, 63)          # sectors/track
    struct.pack_into("<H", bs, 26, 255)         # heads
    struct.pack_into("<I", bs, 28, PART_LBA)    # hidden sectors
    struct.pack_into("<I", bs, 32, part_sectors)
    struct.pack_into("<I", bs, 36, fatsz)       # sectors/FAT32
    struct.pack_into("<H", bs, 40, 0)           # ext flags
    struct.pack_into("<H", bs, 42, 0)           # version
    struct.pack_into("<I", bs, 44, root_clus)
    struct.pack_into("<H", bs, 48, 1)           # FSInfo sector
    struct.pack_into("<H", bs, 50, 6)           # backup boot sector
    bs[64] = 0x80                               # drive number
    bs[66] = 0x29                               # ext boot signature
    struct.pack_into("<I", bs, 67, 0x12345678)  # volume id
    bs[71:82] = b"CXRF     "
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xAA"
    img[base:base + SECTOR] = bs
    img[base + 6 * SECTOR:base + 7 * SECTOR] = bs   # backup

    # ---- FSInfo -------------------------------------------------------
    fsi = bytearray(SECTOR)
    struct.pack_into("<I", fsi, 0, 0x41615252)
    struct.pack_into("<I", fsi, 484, 0x61417272)
    struct.pack_into("<I", fsi, 488, 0xFFFFFFFF)    # free count unknown
    struct.pack_into("<I", fsi, 492, 0xFFFFFFFF)    # next free unknown
    fsi[510:512] = b"\x55\xAA"
    img[base + SECTOR:base + 2 * SECTOR] = fsi

    # ---- FAT allocation ----------------------------------------------
    fat = {}                     # cluster -> next (or 0x0FFFFFFF end)
    fat[0] = 0x0FFFFFF8
    fat[1] = 0x0FFFFFFF

    # The root directory takes as many clusters as its entries need --
    # one 512-byte cluster is only SIXTEEN files, and the seventeenth
    # used to spill into the first file's data and break the boot.
    subdirs = subdirs or {}
    root_entries = len(files) + len(subdirs)
    root_clusters = max(1, (root_entries * 32 + SPC * SECTOR - 1) // (SPC * SECTOR))
    for i in range(root_clusters):
        fat[root_clus + i] = (root_clus + i + 1) if i + 1 < root_clusters else 0x0FFFFFFF

    next_free = root_clus + root_clusters

    def alloc_chain(nbytes):
        nonlocal next_free
        n = max(1, (nbytes + SPC * SECTOR - 1) // (SPC * SECTOR))
        chain = list(range(next_free, next_free + n))
        next_free += n
        for i, c in enumerate(chain):
            fat[c] = chain[i + 1] if i + 1 < n else 0x0FFFFFFF
        return chain

    # ---- root directory entries + file data --------------------------
    root = bytearray()

    def name83(host):
        b = os.path.basename(host).upper()
        stem, dot, ext = b.partition(".")
        stem = (stem[:8] + "        ")[:8]
        ext = (ext[:3] + "   ")[:3]
        return (stem + ext).encode("ascii", "replace")

    def wr(chain, data):
        """write data into its cluster chain"""
        for i, c in enumerate(chain):
            off = base + (data_start - PART_LBA + (c - 2) * SPC) * SECTOR
            chunk = data[i * SPC * SECTOR:(i + 1) * SPC * SECTOR]
            img[off:off + len(chunk)] = chunk

    def entry(name11, attr, first, size):
        ent = bytearray(32)
        ent[0:11] = name11
        ent[11] = attr
        struct.pack_into("<H", ent, 20, (first >> 16) & 0xFFFF)
        struct.pack_into("<H", ent, 26, first & 0xFFFF)
        struct.pack_into("<I", ent, 28, size)
        return ent

    def file_entries(hosts):
        """copy each host file in and return its directory entries"""
        out = bytearray()
        for host in hosts:
            with open(host, "rb") as fh:
                data = fh.read()
            chain = alloc_chain(len(data)) if data else []
            wr(chain, data)
            out += entry(name83(host), 0x20, chain[0] if chain else 0, len(data))
        return out

    # ---- subdirectories: their own cluster chains, "." and ".." first
    subdir_entries = bytearray()
    for dname, dfiles in subdirs.items():
        body = bytearray()
        dot_slot = len(body)                    # filled once the chain is known
        body += bytearray(64)                   # room for "." and ".."
        body += file_entries(dfiles)
        chain = alloc_chain(max(len(body), 1))
        body[0:32]  = entry(b".          ", 0x10, chain[0], 0)
        body[32:64] = entry(b"..         ", 0x10, 0, 0)
        wr(chain, bytes(body))
        n11 = (dname.upper()[:8] + "        ")[:8] + "   "
        subdir_entries += entry(n11.encode("ascii"), 0x10, chain[0], 0)

    for host in files:
        with open(host, "rb") as fh:
            data = fh.read()
        chain = alloc_chain(len(data)) if data else []
        first = chain[0] if chain else 0
        ent = bytearray(32)
        ent[0:11] = name83(host)
        ent[11] = 0x20                          # archive
        struct.pack_into("<H", ent, 20, (first >> 16) & 0xFFFF)
        struct.pack_into("<H", ent, 26, first & 0xFFFF)
        struct.pack_into("<I", ent, 28, len(data))
        root += ent
        wr(chain, data)

    root += subdir_entries              # the folders, after the files

    # root directory into its clusters (contiguous from cluster 2)
    roff = base + (data_start - PART_LBA) * SECTOR
    img[roff:roff + len(root)] = root

    # ---- write both FATs ---------------------------------------------
    fatbytes = bytearray(fatsz * SECTOR)
    for c, v in fat.items():
        struct.pack_into("<I", fatbytes, c * 4, v & 0x0FFFFFFF)
    for i in range(NFAT):
        o = base + (RSVD + i * fatsz) * SECTOR
        img[o:o + len(fatbytes)] = fatbytes

    with open(out, "wb") as f:
        f.write(img)
    ndir = len(subdirs)
    nsub = sum(len(v) for v in subdirs.values())
    print("mksd: %s -- %d MB, %d clusters, %d file(s)%s"
          % (out, IMG_SECTORS * SECTOR // (1024 * 1024), clusters, len(files),
             (" + %d in %d folder(s)" % (nsub, ndir)) if ndir else ""))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = sys.argv[1]
    files = []
    subdirs = {}
    cur = files
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--dir":
            name = args[i + 1]
            cur = subdirs.setdefault(name, [])
            i += 2
            continue
        cur.append(args[i])
        i += 1
    build(out, files, subdirs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
