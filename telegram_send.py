#!/usr/bin/env python3
"""
Send one message via Telegram as the logged-in user (not a bot).
Reads config from the PTT config JSON; requires telegram.api_id, api_hash,
session_path, and target ("me" for Saved Messages, or chat id / username).
Usage: telegram_send.py [--verbose] <config_path> <message>
  or:  echo "message" | telegram_send.py [--verbose] <config_path> -
  --verbose  print which account is sending and to which target (to stderr)
"""
import asyncio
import argparse
import json
import os
import sys
from pathlib import Path


def load_telegram_config(config_path: str) -> dict:
    with open(config_path, "r") as f:
        data = json.load(f)
    tg = data.get("telegram") or {}
    if tg.get("mode") != "user":
        raise SystemExit("telegram_send.py requires telegram.mode='user' in config")
    for key in ("api_id", "api_hash", "session_path", "target"):
        if not tg.get(key):
            raise SystemExit(f"Missing config: telegram.{key}")
    session = Path(tg["session_path"]).expanduser().resolve()
    return {
        "api_id": int(tg["api_id"]),
        "api_hash": tg["api_hash"],
        "session_path": str(session),
        "target": tg["target"].strip(),
    }


async def send(config: dict, text: str, verbose: bool = False) -> None:
    from telethon import TelegramClient

    client = TelegramClient(
        config["session_path"],
        config["api_id"],
        config["api_hash"],
    )
    await client.connect()
    if not await client.is_user_authorized():
        raise SystemExit(
            "Telegram session not authorized. Run telegram_login.py first."
        )
    me = await client.get_me()
    target_key = config["target"]
    if target_key.lower() == "me":
        target = "me"
        target_desc = "Saved Messages (me)"
    else:
        # Numeric ID: resolve entity so Telethon can send (not in cache otherwise)
        try:
            target = await client.get_entity(int(target_key))
            un = getattr(target, "username", None)
            name = getattr(target, "first_name", None) or getattr(target, "title", None)
            target_desc = f"@{un}" if un else (name or f"id {getattr(target, 'id', target_key)}")
        except ValueError:
            target = target_key
            target_desc = target_key
    if verbose:
        print(
            f"Sending as {me.phone or me.id} to {target_desc}",
            file=sys.stderr,
        )
    text = f'<frank>reply-to-office</frank>{text}'
    await client.send_message(target, text)
    await client.disconnect()


def main() -> None:
    parser = argparse.ArgumentParser(description="Send a message via Telegram (user API).")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print sending account and target to stderr")
    parser.add_argument("config_path", help="Path to PTT config JSON")
    parser.add_argument("message", nargs="?", default=None, help="Message text, or '-' to read from stdin")
    args = parser.parse_args()
    if args.message is None:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if args.message == "-":
        text = sys.stdin.read().strip()
    else:
        text = args.message
    if not text:
        sys.exit(0)
    config = load_telegram_config(args.config_path)
    asyncio.run(send(config, text, verbose=args.verbose))


if __name__ == "__main__":
    main()
