#!/usr/bin/env python3
"""
One-time Telegram login as yourself. Creates a session file for telegram_send.py.
Get api_id and api_hash from https://my.telegram.org/apps
Usage: telegram_login.py <config_path>
Config must already have telegram.api_id, telegram.api_hash, telegram.session_path.
After running, enter your phone number and the code Telegram sends you.
"""
import asyncio
import json
import sys
from pathlib import Path


def load_config(config_path: str) -> dict:
    with open(config_path, "r") as f:
        data = json.load(f)
    tg = data.get("telegram") or {}
    for key in ("api_id", "api_hash", "session_path"):
        if not tg.get(key):
            raise SystemExit(f"Missing config: telegram.{key}. Create config first.")
    session = Path(tg["session_path"]).expanduser().resolve()
    return {
        "api_id": int(tg["api_id"]),
        "api_hash": tg["api_hash"],
        "session_path": str(session),
    }


async def login(config: dict) -> None:
    from telethon import TelegramClient
    from telethon.errors import SessionPasswordNeededError

    client = TelegramClient(
        config["session_path"],
        config["api_id"],
        config["api_hash"],
    )
    await client.connect()
    if await client.is_user_authorized():
        me = await client.get_me()
        print(f"Already logged in as {me.phone}")
        await client.disconnect()
        return
    phone = input("Enter your phone number (e.g. +1234567890): ").strip()
    await client.send_code_request(phone)
    code = input("Enter the code you received: ").strip()
    try:
        await client.sign_in(phone, code)
    except SessionPasswordNeededError:
        pw = input("Enter your 2FA password: ").strip()
        await client.sign_in(password=pw)
    me = await client.get_me()
    print(f"Logged in as {me.phone}. Session saved to {config['session_path']}")
    await client.disconnect()


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    config = load_config(sys.argv[1])
    asyncio.run(login(config))


if __name__ == "__main__":
    main()
