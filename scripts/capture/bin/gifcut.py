#!/usr/bin/env python3
"""gifcut.py IN OUT.gif --seg S:E[:SPEED] [--seg ...] [--fps 20] [--hold 0.8] [--crop W:H:X:Y] [--room] [--top 12]

Edits a lossless take into a GIF.
  --seg    S:E[:SPEED] seconds of the take (E may be 'end'), retimed by SPEED; segments are concatenated in order.
  --crop   W:H:X:Y in take pixels, applied to every frame (keep X, Y, W, H multiples of the art pixel: 4 or 2).
  --hold   seconds the last frame is held.
  --room   whole-room take (1176x736 from record.sh's default): patches the widget corner on every frame with the
           clean plate of the frame's lighting phase (gif/fixed-<phase>.png, 306x162 at 0,0, feathered right and
           bottom), plus a per-row colour offset measured on the wall just right of the patch (x 310-470), so the
           menu-bar backdrop band and any colour drift continue across the seam (rows 0-99; lower rows reuse the offset of rows 60-99,
           because the clock and the monitor sit right of the patch there). Then --top rows are cropped.
The edited frames are kept losslessly in cap/edit/<name>.mkv; the GIF gets a palette from the clip
(max_colors=256, stats_mode=diff) and paletteuse dither=none, diff_mode=rectangle.
"""
import argparse, os, subprocess, sys
import numpy as np

C = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G = os.path.join(C, 'gif')
ap = argparse.ArgumentParser()
ap.add_argument('inp'); ap.add_argument('out')
ap.add_argument('--seg', action='append', required=True)
ap.add_argument('--fps', type=float, default=20)
ap.add_argument('--hold', type=float, default=0.8)
ap.add_argument('--crop', default=None)
ap.add_argument('--room', action='store_true')
ap.add_argument('--top', type=int, default=12)
ap.add_argument('--phases', default='day,night,lamponly')
ap.add_argument('--force', default=None)
ap.add_argument('--quiet', action='store_true')
a = ap.parse_args()

def probe(p):
    s = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height',
                        '-of', 'csv=s=x:p=0', p], capture_output=True, text=True, check=True).stdout.strip()
    return tuple(map(int, s.split('x')))

W0, H0 = probe(a.inp)
if a.crop:
    cw, ch, cx, cy = map(int, a.crop.split(':'))
else:
    cw, ch, cx, cy = W0, H0, 0, 0

frames = []
for seg in a.seg:
    parts = seg.split(':')
    s = float(parts[0]); e = parts[1]; sp = float(parts[2]) if len(parts) > 2 else 1.0
    cmd = ['ffmpeg', '-v', 'error', '-ss', str(s)]
    if e != 'end': cmd += ['-to', e]
    vf = f"setpts=(PTS-STARTPTS)/{sp},fps={a.fps}"
    if a.crop and not a.room: vf += f",crop={cw}:{ch}:{cx}:{cy}"
    cmd += ['-i', a.inp, '-vf', vf, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    w, h = (W0, H0) if (a.room or not a.crop) else (cw, ch)
    arr = np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)
    frames.extend(list(arr))
    if not a.quiet: print(f"seg {seg}: {len(arr)} frames")
nhold = int(round(a.hold * a.fps))
frames += [frames[-1]] * nhold

if a.room:
    cols = {'day': (0xeb, 0xed, 0xe9), 'night': (0xe7, 0xd5, 0xb3), 'lamponly': (0x25, 0x3a, 0x5e)}
    phases = a.phases.split(',')
    plates = {}
    for p in phases:
        raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', os.path.join(G, f'fixed-{p}.png'), '-f', 'rawvideo',
                              '-pix_fmt', 'rgb24', '-'], capture_output=True, check=True).stdout
        plates[p] = np.frombuffer(raw, np.uint8).reshape(738, 1176, 3).astype(np.float32)
    PW, PH = 306, 162
    X = np.arange(PW)[None, :]; Y = np.arange(PH)[:, None]
    alpha = np.clip(np.minimum((PW - 1 - X) / 10.0, (PH - 1 - Y) / 7.0), 0, 1)[:, :, None].astype(np.float32)
    out, seq = [], []
    for f in frames:
        f = f.astype(np.float32)
        smp = f[50:90, 320:380].reshape(-1, 3).mean(axis=0)
        ph = a.force or min(phases, key=lambda p: sum((smp[i] - cols[p][i]) ** 2 for i in range(3)))
        seq.append(ph)
        pl = plates[ph]
        # per-row offset: wall right of the patch, live minus plate (medians ignore the string lights and the clock)
        # rows 0..99 right of the patch are bare wall and string lights; lower rows hold the clock and the monitor,
        # so they take the steady offset measured on rows 60..99
        WR = 100
        off = np.median(f[:WR, 310:470], axis=1) - np.median(pl[:WR, 310:470], axis=1)   # WR x 3
        # smooth along y (5-row running median) so a cursor or a bulb cannot jolt one row
        pad = np.pad(off, ((2, 2), (0, 0)), mode='edge')
        off = np.median(np.stack([pad[i:i + WR] for i in range(5)]), axis=0)
        off = np.concatenate([off, np.repeat(np.median(off[60:WR], axis=0)[None, :], PH - WR, axis=0)])
        patch = np.clip(pl[:PH, :PW] + off[:, None, :], 0, 255)
        f[:PH, :PW] = f[:PH, :PW] * (1 - alpha) + patch * alpha
        out.append(np.clip(f[a.top:] + 0.5, 0, 255).astype(np.uint8))
    frames = out
    segs = []
    for i, p in enumerate(seq):
        if segs and segs[-1][0] == p: segs[-1][2] = i
        else: segs.append([p, i, i])
    if not a.quiet: print('phases', segs)
    if a.crop:
        frames = [f[cy:cy + ch, cx:cx + cw] for f in frames]

h, w = frames[0].shape[:2]
name = os.path.splitext(os.path.basename(a.out))[0]
os.makedirs(os.path.join(C, 'edit'), exist_ok=True)
inter = os.path.join(C, 'edit', name + '.mkv')
pal = os.path.join(C, 'edit', name + '-pal.png')
p = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{w}x{h}', '-r', str(a.fps),
                      '-i', '-', '-c:v', 'ffv1', '-pix_fmt', 'bgr0', inter], stdin=subprocess.PIPE)
for f in frames: p.stdin.write(np.ascontiguousarray(f).tobytes())
p.stdin.close(); p.wait()
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', inter, '-vf', 'palettegen=max_colors=256:stats_mode=diff', pal], check=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', inter, '-i', pal, '-lavfi', 'paletteuse=dither=none:diff_mode=rectangle',
                '-loop', '0', a.out], check=True)
n = len(frames)
print(f"{a.out} {w}x{h} {os.path.getsize(a.out)} bytes {n} frames {n / a.fps:.2f}s (hold {nhold} f)")
