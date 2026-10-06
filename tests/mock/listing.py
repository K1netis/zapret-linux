# Ответ GitHub contents API для каталога: список файлов с download_url.
import json, os, sys, urllib.parse
root, sub = sys.argv[1], sys.argv[2].strip("/")
d = os.path.join(root, sub)
items = []
for name in sorted(os.listdir(d)):
    if name.startswith("."):
        continue
    rel = (sub + "/" + name).strip("/")
    if os.path.isdir(os.path.join(d, name)):
        items.append({"name": name, "type": "dir", "download_url": None})
    else:
        items.append({"name": name, "type": "file",
                      "download_url": "http://mock/raw/" + urllib.parse.quote(rel)})
# Дополнительные «сырые» ссылки (для проверки подозрительных имён): файл
# .extra_urls в каталоге, по одной ссылке на строку. Имя берётся из ссылки,
# как у настоящего API.
extra = os.path.join(d, ".extra_urls")
if os.path.isfile(extra):
    for line in open(extra, encoding="utf-8").read().splitlines():
        line = line.strip()
        if line:
            items.append({"name": line.rsplit("/", 1)[-1], "type": "file",
                          "download_url": line})
print(json.dumps(items, indent=2))
