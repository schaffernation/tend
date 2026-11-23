#!/usr/bin/env python3
"""Write the .DS_Store that lays out Tend's disk image window.

Usage: make-dsstore.py MOUNT VOLNAME BACKGROUND WIDTH HEIGHT ICONSIZE NAME=X,Y...

MOUNT is where the read-write image is mounted, VOLNAME is its volume name,
and BACKGROUND is the background picture's path relative to MOUNT. WIDTH and
HEIGHT are the window's content size in points. Each NAME=X,Y places an item's
icon center, in points from the top left of the window.

app/make-dmg.sh runs this script. It writes the file Finder would write, so
the layout doesn't depend on scripting Finder, which needs Automation
permission and a logged-in window server. The format follows the reverse
engineered descriptions of the .DS_Store buddy allocator and of Alias Manager
records (as in the ds_store and mac_alias Python packages). Standard library
only.
"""

import os
import plistlib
import struct
import sys

MAC_EPOCH = 2082844800  # Seconds from 1904-01-01 to 1970-01-01.
TITLE_BAR = 32          # Finder's window bounds include the title bar (28 before macOS 26).


def pascal(text, size):
    data = text.encode("mac_roman", "replace")[: size - 1]
    return bytes([len(data)]) + data + b"\0" * (size - 1 - len(data))


def alias(mount, volname, relpath):
    """An Alias Manager record (version 2) for a file on the mounted volume.

    Finder resolves it by volume name and path when the image is mounted
    again, wherever it's mounted.
    """
    target = os.path.join(mount, relpath)
    parent = os.path.dirname(target)
    vol, folder, st = os.stat(mount), os.stat(parent), os.stat(target)
    name = os.path.basename(target)
    record = struct.pack(
        ">h28pI2shI64pII4s4shhI2s10s",
        0,                                   # Kind: file.
        volname.encode("mac_roman")[:27],
        int(vol.st_birthtime) + MAC_EPOCH,
        b"H+",
        5,                                   # Disk type: ejectable.
        folder.st_ino,                       # Parent CNID.
        name.encode("mac_roman")[:63],
        st.st_ino,                           # File CNID.
        int(st.st_birthtime) + MAC_EPOCH,
        b"\0" * 4, b"\0" * 4,                # Creator and type codes.
        -1, -1,                              # Levels from and to the root.
        0, b"\0\0", b"\0" * 10)

    def tag(number, data):
        out = struct.pack(">hh", number, len(data)) + data
        return out + b"\0" if len(data) % 2 else out

    def unicode(text):
        return struct.pack(">h", len(text)) + text.encode("utf-16-be")

    posix = "/" + relpath.strip("/")
    extras = b"".join([
        tag(0, os.path.basename(parent).encode("mac_roman")),
        tag(1, struct.pack(">I", folder.st_ino)),
        tag(2, (volname + posix.replace("/", ":")).encode("mac_roman")),
        tag(14, unicode(name)),
        tag(15, unicode(volname)),
        tag(18, posix.encode("utf-8")),
        tag(19, ("/Volumes/" + volname).encode("utf-8")),
    ]) + b"\xff\xff\x00\x00"
    body = record + extras
    return struct.pack(">4shh", b"\0" * 4, 8 + len(body), 2) + body


def entry(filename, code, kind, value):
    out = struct.pack(">I", len(filename)) + filename.encode("utf-16-be")
    out += code.encode("ascii") + kind.encode("ascii")
    if kind == "long":
        out += struct.pack(">I", value)
    elif kind == "type":
        out += value.encode("ascii")
    elif kind == "blob":
        out += struct.pack(">I", len(value)) + value
    else:
        raise ValueError(kind)
    return out


class Buddy:
    """The buddy allocator the .DS_Store file format is built on."""

    def __init__(self):
        self.free = [[] for _ in range(32)]
        self.free[31] = [0]
        self.blocks = []  # (offset, width, data)

    def allocate(self, size):
        width = max(5, (size - 1).bit_length())
        k = width
        while not self.free[k]:
            k += 1
        offset = self.free[k].pop(0)
        while k > width:
            k -= 1
            self.free[k].append(offset + (1 << k))
            self.free[k].sort()
        return offset, width

    def add(self, data):
        offset, width = self.allocate(len(data))
        self.blocks.append((offset, width, data))
        return len(self.blocks) - 1


def dsstore(records):
    records.sort(key=lambda r: (r[0].lower(), r[1]))
    buddy = Buddy()
    buddy.allocate(32)                    # The file header.
    root = buddy.allocate(2048)           # The allocator's own block, block 0.
    buddy.blocks.append(root + (None,))
    node = struct.pack(">II", 0, len(records)) + b"".join(entry(*r) for r in records)
    node_id = buddy.add(node.ljust(4096, b"\0"))
    dsdb_id = buddy.add(struct.pack(">IIIII", node_id, 0, len(records), 1, 4096))

    addresses = [offset | width for offset, width, _ in buddy.blocks]
    info = struct.pack(">II", len(addresses), 0)
    info += b"".join(struct.pack(">I", a) for a in addresses)
    info += b"\0" * 4 * (-len(addresses) % 256)
    info += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", dsdb_id)
    for k in range(32):
        info += struct.pack(">I", len(buddy.free[k]))
        info += b"".join(struct.pack(">I", o) for o in buddy.free[k])
    assert len(info) <= 2048, "allocator block overflow"

    blocks = [(root[0], root[1], info)] + buddy.blocks[1:]
    size = max(offset + (1 << width) for offset, width, _ in blocks)
    body = bytearray(size)
    body[0:4] = b"Bud1"
    body[4:16] = struct.pack(">III", root[0], 1 << root[1], root[0])
    body[16:32] = bytes.fromhex("0000100c000000870000200b00000000")
    for offset, width, data in blocks:
        body[offset:offset + len(data)] = data
    return b"\0\0\0\1" + bytes(body)


def main(argv):
    if len(argv) < 8:
        sys.exit(__doc__.strip().splitlines()[2])
    mount, volname, background = argv[1:4]
    width, height, icon = (int(v) for v in argv[4:7])
    window = {
        "WindowBounds": "{{200, 120}, {%d, %d}}" % (width, height + TITLE_BAR),
        "ShowToolbar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
        "ShowStatusBar": False, "ShowPathbar": False, "ShowTabView": False,
        "PreviewPaneVisibility": False, "SidebarWidth": 0,
    }
    view = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": alias(mount, volname, background),
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "iconSize": float(icon), "textSize": 13.0, "labelOnBottom": True,
        "arrangeBy": "none", "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "showIconPreview": True, "showItemInfo": False,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    binary = plistlib.FMT_BINARY
    records = [
        (".", "bwsp", "blob", plistlib.dumps(window, fmt=binary)),
        (".", "icvp", "blob", plistlib.dumps(view, fmt=binary)),
        (".", "vSrn", "long", 1),
        (".", "vstl", "type", "icnv"),
    ]
    for item in argv[7:]:
        name, _, point = item.rpartition("=")
        x, y = (int(v) for v in point.split(","))
        location = struct.pack(">II", x, y) + b"\xff" * 6 + b"\0\0"
        records.append((name, "Iloc", "blob", location))
    with open(os.path.join(mount, ".DS_Store"), "wb") as f:
        f.write(dsstore(records))


if __name__ == "__main__":
    main(sys.argv)
