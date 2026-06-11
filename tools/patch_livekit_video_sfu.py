#!/usr/bin/env python3
"""Enable LiveKit media sessions for video broadcasts (not only audio)."""

from __future__ import annotations

import sys
from pathlib import Path


def patch_socket_js(text: str) -> str:
    if "function canPublishLiveMedia(" in text:
        print("socket.js already patched for video SFU", file=sys.stderr)
        return text

    text = text.replace(
        "function canPublishLiveAudio(room, userId) {\n"
        "  if (!room || room.type !== \"audio\") return false;\n"
        "  return room.hostUserId === String(userId) || isLiveSpeaker(room, userId);\n"
        "}",
        "function canPublishLiveMedia(room, userId) {\n"
        "  if (!room) return false;\n"
        "  const type = String(room.type || \"audio\").trim().toLowerCase();\n"
        "  if (type !== \"audio\" && type !== \"video\") return false;\n"
        "  return room.hostUserId === String(userId) || isLiveSpeaker(room, userId);\n"
        "}\n"
        "\n"
        "function canPublishLiveAudio(room, userId) {\n"
        "  return canPublishLiveMedia(room, userId);\n"
        "}",
    )

    text = text.replace(
        "  if (!hasLivekitConfig() || !room || room.type !== \"audio\") return null;",
        "  if (!hasLivekitConfig() || !room) return null;\n"
        "  const roomType = String(room.type || \"audio\").trim().toLowerCase();\n"
        "  if (roomType !== \"audio\" && roomType !== \"video\") return null;",
    )

    text = text.replace(
        "    canPublish: Boolean(canPublish),\n"
        "  });\n"
        "  return {\n"
        "    url: getLivekitPublicUrl(),\n"
        "    token: await accessToken.toJwt(),\n"
        "    canPublish: Boolean(canPublish),\n"
        "  };",
        "    canPublish: Boolean(canPublish),\n"
        "  });\n"
        "  return {\n"
        "    url: getLivekitPublicUrl(),\n"
        "    token: await accessToken.toJwt(),\n"
        "    canPublish: Boolean(canPublish),\n"
        "    publishVideo: roomType === \"video\" && Boolean(canPublish),\n"
        "    roomType,\n"
        "  };",
    )

    text = text.replace(
        "  if (!roomService || !room || room.type !== \"audio\") return false;",
        "  if (!roomService || !room) return false;\n"
        "  const roomType = String(room.type || \"audio\").trim().toLowerCase();\n"
        "  if (roomType !== \"audio\" && roomType !== \"video\") return false;",
    )

    text = text.replace(
        "      if (room.type !== \"audio\") {\n"
        "        return ack?.({ ok: false, message: \"media session is only used for audio rooms\" });",
        "      const mediaRoomType = String(room.type || \"audio\").trim().toLowerCase();\n"
        "      if (mediaRoomType !== \"audio\" && mediaRoomType !== \"video\") {\n"
        "        return ack?.({ ok: false, message: \"media session is not available for this room type\" });",
    )

    return text


def main() -> int:
    target = Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/talkflix-api/socket.js")
    original = target.read_text(encoding="utf-8")
    patched = patch_socket_js(original)
    if patched == original:
        print("No changes applied", file=sys.stderr)
        return 1
    target.write_text(patched, encoding="utf-8")
    print(f"Patched {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
