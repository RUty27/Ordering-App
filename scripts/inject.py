# Builds dist/ from the template + data/data.json, plus the PWA files (manifest, service worker, icons)
import json, pathlib, shutil
root = pathlib.Path(__file__).resolve().parent.parent
dist = root/"dist"
data = json.dumps(json.loads((root/"data/data.json").read_text(encoding="utf-8")), ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
html = (root/"index.template.html").read_text(encoding="utf-8").replace("__DATA__", data)
dist.mkdir(exist_ok=True)
(dist/"index.html").write_text(html, encoding="utf-8")
for f in ("manifest.webmanifest", "sw.js"):
    shutil.copy(root/f, dist/f)
shutil.copytree(root/"icons", dist/"icons", dirs_exist_ok=True)
print("Wrote dist/")
