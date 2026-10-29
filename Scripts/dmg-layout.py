#!/usr/bin/env python3
"""Lays out the window of Riffle's disk image: the background with the arrow, the app and the link to Applications
side by side, no toolbar or sidebar. Finder keeps a folder's window in a .DS_Store file; this writes that file into the
mounted image before it is made read-only.

  python3 Scripts/dmg-layout.py <mount point> <volume name> <background file in the volume>

Standard library only. The file is Finder's store: a small "buddy" allocator holding one B-tree page of records. The
background is named the way Finder names it, by a classic alias record (version 2): the volume's name and creation
date, the picture's file number and its folder's, with its path as a fallback. Make sure the volume is HFS+ and that
nothing is copied onto it after this runs, or the file numbers change.
"""
import os
import plistlib
import struct
import sys

MAC_EPOCH = 2082844800  # seconds from 1904-01-01 to 1970-01-01, both UTC

# The window: 660 × 400 points of picture under a title bar, the icons centred at these points, 128 points large.
WINDOW = {"x": 200, "y": 120, "width": 660, "height": 428}
ICON_SIZE = 128
ICONS = {"Riffle.app": (170, 200), "Applications": (490, 200)}


def pascal(text, size):
    data = text.encode("utf-8")[: size - 1]
    return bytes([len(data)]) + data + b"\0" * (size - 1 - len(data))


def tag(number, data):
    out = struct.pack(">hH", number, len(data)) + data
    return out + (b"\0" if len(data) & 1 else b"")


def alias(mount, volume_name, path):
    """A version 2 alias record for `path`, on the volume mounted at `mount` and named `volume_name`."""
    file_stat = os.stat(path)
    folder = os.path.dirname(path)
    folder_stat = os.stat(folder)
    volume_date = os.stat(mount).st_birthtime + MAC_EPOCH
    file_date = file_stat.st_birthtime + MAC_EPOCH
    relative = os.path.relpath(path, mount)
    parts = relative.split(os.sep)
    # The file numbers of the folders between the volume and the file, nearest first.
    chain, head = [], os.path.dirname(relative)
    while head:
        chain.append(os.stat(os.path.join(mount, head)).st_ino)
        head = os.path.dirname(head)
    filename = os.path.basename(path)

    fixed = (
        struct.pack(">h", 0)  # kind: a file
        + pascal(volume_name.replace(":", "/"), 28)
        + struct.pack(">I", int(volume_date))
        + b"H+"
        + struct.pack(">h", 0)  # disk type: fixed
        + struct.pack(">I", folder_stat.st_ino)
        + pascal(filename.replace(":", "/"), 64)
        + struct.pack(">I", file_stat.st_ino)
        + struct.pack(">I", int(file_date))
        + b"\0\0\0\0" + b"\0\0\0\0"  # creator and type
        + struct.pack(">hh", -1, -1)  # levels from and to
        + struct.pack(">I", 0)  # volume attributes
        + b"\0\0"  # volume file system id
        + b"\0" * 10
    )
    tags = b""
    tags += tag(0, os.path.basename(folder).replace(":", "/").encode("utf-8"))
    tags += struct.pack(">hHQ", 16, 8, int(volume_date * 65536))
    tags += struct.pack(">hHQ", 17, 8, int(file_date * 65536))
    if chain:
        tags += tag(1, struct.pack(">%dI" % len(chain), *chain))
    tags += tag(2, (volume_name + ":" + ":".join(p.replace(":", "/") for p in parts)).encode("utf-8"))
    name16 = filename.replace(":", "/").encode("utf-16-be")
    tags += tag(14, struct.pack(">H", len(name16) // 2) + name16)
    volume16 = volume_name.replace(":", "/").encode("utf-16-be")
    tags += tag(15, struct.pack(">H", len(volume16) // 2) + volume16)
    tags += tag(18, ("/" + relative).encode("utf-8"))
    tags += tag(19, ("/Volumes/" + volume_name).encode("utf-8"))
    tags += struct.pack(">hH", -1, 0)

    body = fixed + tags
    size = 8 + len(body)
    return b"\0\0\0\0" + struct.pack(">Hh", size, 2) + body


def entry(name, code, kind, value):
    name16 = name.encode("utf-16-be")
    out = struct.pack(">I", len(name16) // 2) + name16 + code + kind
    if kind == b"long":
        return out + struct.pack(">I", value)
    if kind == b"blob":
        return out + struct.pack(">I", len(value)) + value
    raise ValueError(kind)


def store(records):
    """Finder's .DS_Store bytes for `records`: (name, code, type, value), already in Finder's order."""
    # Blocks, as offsets past the 4-byte file magic: the header takes [0, 32), the store's master record [32, 64), the
    # allocator's own table [2048, 4096) and the one B-tree page [4096, 8192).
    master_at, master_log = 32, 5
    table_at, table_log = 2048, 11
    page_at, page_log = 4096, 12
    addresses = [table_at | table_log, master_at | master_log, page_at | page_log]  # blocks 0, 1, 2

    page = struct.pack(">II", 0, len(records)) + b"".join(entry(*r) for r in records)
    if len(page) > 1 << page_log:
        raise ValueError("the records don't fit in one page")
    master = struct.pack(">IIIII", 2, 0, len(records), 1, 1 << page_log)  # root page, levels, records, pages, page size

    table = struct.pack(">II", len(addresses), 0)
    table += struct.pack(">256I", *(addresses + [0] * (256 - len(addresses))))
    table += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    # The free space, split the buddy way over the 2^31 bytes an allocator spans.
    free = {6: [64], 7: [128], 8: [256], 9: [512], 10: [1024]}
    for n in range(13, 31):
        free[n] = [1 << n]
    for n in range(32):
        blocks = free.get(n, [])
        table += struct.pack(">I", len(blocks)) + b"".join(struct.pack(">I", b) for b in blocks)

    data = bytearray(1 << 13)
    header = b"Bud1" + struct.pack(">III", table_at, 1 << table_log, table_at)
    header += bytes.fromhex("0000100c000000870000200b00000000")
    data[0 : len(header)] = header
    data[master_at : master_at + len(master)] = master
    data[table_at : table_at + len(table)] = table
    data[page_at : page_at + len(page)] = page
    return struct.pack(">I", 1) + bytes(data)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    mount, volume_name, background = sys.argv[1:]
    bwsp = {
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 180,
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (WINDOW["x"], WINDOW["y"], WINDOW["width"], WINDOW["height"]),
    }
    icvp = {
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundImageAlias": alias(mount, volume_name, os.path.join(mount, background)),
        "backgroundType": 2,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": float(ICON_SIZE),
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": True,
        "showItemInfo": False,
        "textSize": 13.0,
        "viewOptionsVersion": 1,
    }
    records = [
        (".", b"bwsp", b"blob", plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)),
        (".", b"icvp", b"blob", plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)),
        (".", b"vSrn", b"long", 1),
    ]
    # Finder keeps records by name, without regard to case, then by code.
    for name in sorted(ICONS, key=str.lower):
        x, y = ICONS[name]
        records.append((name, b"Iloc", b"blob", struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000)))
    with open(os.path.join(mount, ".DS_Store"), "wb") as f:
        f.write(store(records))
    # The alias on its own, for the check in Scripts/make-dmg.sh.
    if os.environ.get("RIFFLE_ALIAS_OUT"):
        with open(os.environ["RIFFLE_ALIAS_OUT"], "wb") as f:
            f.write(icvp["backgroundImageAlias"])


if __name__ == "__main__":
    main()
