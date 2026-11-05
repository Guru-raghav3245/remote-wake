# Renders an animation page frame by frame (headless Chrome via playwright) and encodes an mp4 with ffmpeg.
# Page must expose update(t). Usage:
#   python3 render.py PAGE.html OUT.mp4 W H FPS DUR            full video
#   python3 render.py PAGE.html OUTPREFIX W H FPS DUR t1,t2    still frames
import sys, subprocess, pathlib, tempfile
from playwright.sync_api import sync_playwright
page, out, W, H, fps, DUR = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6])
here = pathlib.Path(__file__).parent
with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    pg = b.new_page(viewport={"width": W, "height": H})
    pg.goto((here / page).as_uri())
    if len(sys.argv) > 7:
        for t in sys.argv[7].split(","):
            pg.evaluate(f"update({t})"); pg.screenshot(path=f"{out}-{t}.png")
        sys.exit()
    tmp = pathlib.Path(tempfile.mkdtemp())
    for i in range(int(fps * DUR)):
        pg.evaluate(f"update({i / fps})"); pg.screenshot(path=str(tmp / f"{i:05d}.png"))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", str(tmp / "%05d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", out], check=True)
