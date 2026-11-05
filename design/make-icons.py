#!/usr/bin/env python3
"""Renders all app icons from design/icon-render.html (headless Chrome) into the Mac and Android projects. Run from anywhere."""
import base64, json, os, re, subprocess, sys
D = os.path.dirname(os.path.abspath(__file__)); R = os.path.dirname(D)
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
dom = subprocess.run([chrome, "--headless=new", "--disable-gpu", "--virtual-time-budget=8000", "--dump-dom", "file://" + D + "/icon-render.html"], capture_output=True, text=True, check=True).stdout
out = json.loads(re.search(r'<pre id="out">(.*?)</pre>', dom, re.S).group(1).replace("&quot;", '"').replace("&amp;", "&"))
def save(key, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(base64.b64decode(out[key].split(",", 1)[1]))
iconset = "/tmp/rw.iconset"
for k in out:
    if k.startswith("mac/"): save(k, f"{iconset}/{k[4:]}.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", f"{R}/app/AppIcon.icns"], check=True)
res = f"{R}/android-app/android/app/src/main/res"
for d in ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]: save(f"android/legacy-{d}", f"{res}/mipmap-{d}/ic_launcher.png")
save("android/fg", f"{res}/drawable-nodpi/ic_launcher_fg.png"); save("android/mono", f"{res}/drawable-nodpi/ic_launcher_mono.png")
for d in ["mdpi", "hdpi", "xhdpi", "xxhdpi"]: save(f"android/stat-{d}", f"{res}/drawable-{d}/ic_stat.png")
save("logo/1024", f"{R}/android-app/assets/icon.png"); save("logo/128", f"{R}/app/logo.png")
print("ok", len(out), "images")
