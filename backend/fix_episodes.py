"""One-time repair: videos uploaded by the Drive agent with a wrong/missing season + episode.

Reads every Drive-agent document (id "drive_...") from Firestore, re-detects season/episode from its
title with the fixed parser, and fills `season` / `episodes` (and the cleaned title).

    python fix_episodes.py            # preview only, nothing is written
    python fix_episodes.py --apply    # write the fixes

Run it inside backend/ (needs the same .env / serviceAccount.json the server uses).
"""
import sys

from dotenv import load_dotenv

load_dotenv()

import firebase_admin
from firebase_admin import firestore

from drive_agent.auth import load_credentials
from drive_agent.models import DriveVideo
from drive_agent.parser import parse


def num(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return 0


def main(apply: bool) -> None:
    if not firebase_admin._apps:
        firebase_admin.initialize_app(load_credentials())
    col = firestore.client().collection("videos")
    seen = fixed = 0
    for doc in col.stream():
        if not doc.id.startswith("drive_"):
            continue
        d = doc.to_dict() or {}
        if d.get("category") != "series":
            continue
        seen += 1
        m = parse(DriveVideo(file_id=doc.id, name=str(d.get("title", ""))), "series")
        if m.season <= 0 or m.episode <= 0:
            print(f"SKIP  {d.get('title')}  (could not detect)")
            continue
        upd = {}
        if num(d.get("season")) != m.season:
            upd["season"] = m.season
        if num(d.get("episodes")) != m.episode:
            upd["episodes"] = m.episode
        if not upd:
            continue
        if num(d.get("season")) == 0 and num(d.get("episodes")) == 0 and m.title and m.title != d.get("title"):
            upd["title"] = m.title                      # only the untouched, wrongly-parsed ones
        fixed += 1
        print(f"{'FIX ' if apply else 'WOULD FIX'}  {d.get('title')}  ->  S{m.season} E{m.episode}")
        if apply:
            doc.reference.update(upd)
    print(f"\n{seen} drive videos checked, {fixed} {'fixed' if apply else 'need fixing'}.")
    if fixed and not apply:
        print("Run again with --apply to write them.")


if __name__ == "__main__":
    main("--apply" in sys.argv)
