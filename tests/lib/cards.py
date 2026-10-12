# stand-ins for images and cards in the device-free flash and ota scenarios: just
# enough of a partition table for `raspi-provision` to find where persist starts.

import os
import struct

SECTOR = 512
# what toolbox/build-image leaves at the head of an image whose initramfs adopts
# a persist partition it did not make
KEEP_MAGIC = b"raspi-provision keep 1"
# the third of an mbr's four primary partition entries: its first sector and its
# length in sectors, after eight bytes nothing here reads
ENTRY = struct.Struct("<8xII")
ENTRY_OFFSET = 446 + 2 * 16
# more than one dd block, ending in a partial one
IMAGE_BYTES = 5 * 1024 * 1024 + SECTOR
# where the image's persist partition starts, and how long the fresh one is
PERSIST_START = 2 * 1024 * 1024 // SECTOR
FRESH_SECTORS = (IMAGE_BYTES - PERSIST_START * SECTOR) // SECTOR


def table(magic: bytes, start: int, sectors: int) -> bytes:
    """an mbr whose third partition is at `start`"""
    mbr = bytearray(SECTOR)
    mbr[:len(magic)] = magic
    mbr[ENTRY_OFFSET:ENTRY_OFFSET + ENTRY.size] = ENTRY.pack(start, sectors)
    mbr[-2:] = b"\x55\xaa"
    return bytes(mbr)


def image_data(magic: bytes = KEEP_MAGIC) -> bytes:
    """an image of random contents with a persist partition at PERSIST_START"""
    return table(magic, PERSIST_START, FRESH_SECTORS) + os.urandom(IMAGE_BYTES - SECTOR)
