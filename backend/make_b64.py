import base64, json, re
from pathlib import Path

text = Path(".env").read_text(encoding="utf-8")
m = re.search(r"FIREBASE_SERVICE_ACCOUNT_JSON\s*=\s*['\"]?(\{.*?\})['\"]?\s*(?:\r?\n[A-Za-z_]+=|\Z)", text, re.S)
if not m:
    raise SystemExit("JSON block .env la kidaikkala")
info = json.loads(m.group(1), strict=False)
Path("sa_b64.txt").write_text(base64.b64encode(json.dumps(info).encode()).decode())
print("Done -> sa_b64.txt", info.get("project_id"))
