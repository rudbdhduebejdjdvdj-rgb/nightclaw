"""Local AeroWash Vision camera dashboard.
Reads the frames already produced by the camera pipeline; does not open the camera,
so it can run alongside bot.py. Digital zoom is software crop/resize, not optical zoom.
Run: python3 camera_dashboard.py
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import cv2
import numpy as np

ROOT = Path.home() / "AeroWashVision"
FRAME_DIR = ROOT / "dataset" / "connector"
RAW = Path(os.environ.get("AEROWASH_RAW_PATH", str(FRAME_DIR / "latest_raw.jpg")))
PROCESSED = Path(os.environ.get("AEROWASH_FRAME_PATH", str(FRAME_DIR / "latest.jpg")))
HOST = os.environ.get("AEROWASH_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("AEROWASH_UI_PORT", "8765"))
LOCK = threading.Lock()
CACHE = {}
SETTINGS = {"zoom": 1.0, "sensitivity": 2, "purple": True, "source": "raw"}

HTML = r"""<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AeroWash Vision · Cámara</title>
<style>
:root{color-scheme:dark;--bg:#080b12;--panel:#111827;--line:#263246;--muted:#9aa9bf;--purple:#d946ef;--cyan:#22d3ee}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(ellipse at top,#152033,#080b12 55%);color:#eef4ff;font:14px/1.45 -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif}
header{display:flex;justify-content:space-between;align-items:center;padding:18px 24px;border-bottom:1px solid var(--line);position:sticky;top:0;background:#080b12ee;backdrop-filter:blur(12px);z-index:3}
.brand{display:flex;gap:12px;align-items:center}.logo{width:38px;height:38px;border-radius:12px;background:linear-gradient(135deg,#a855f7,#06b6d4);display:grid;place-items:center;font-weight:900;color:white;font-size:18px}
h1{font-size:17px;margin:0}small,.muted{color:var(--muted)}.status{color:#a3e635;font-size:12px}.layout{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:16px;padding:18px;max-width:1600px;margin:auto}
.card{background:linear-gradient(160deg,#121b2b,#0e1420);border:1px solid var(--line);border-radius:18px;overflow:hidden}.cardhead{padding:14px 16px;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:center}.view{position:relative;background:#03060b;min-height:340px;display:grid;place-items:center;overflow:hidden}.view img{width:100%;height:auto;max-height:75vh;object-fit:contain;display:block}.overlay{position:absolute;left:12px;top:12px;background:#070a10d9;border:1px solid #ffffff20;border-radius:9px;padding:8px 10px;font-size:11px}.pill{border:1px solid var(--line);padding:5px 9px;border-radius:999px;color:var(--muted);font-size:11px}.controls{padding:16px;display:grid;gap:18px}.control{display:grid;gap:8px}.labelrow{display:flex;justify-content:space-between;gap:8px}.labelrow label{font-weight:650}.value{color:#e879f9;font-variant-numeric:tabular-nums}input[type=range]{width:100%;accent-color:#d946ef}select,button{border:1px solid var(--line);background:#182235;color:#eef4ff;border-radius:10px;padding:10px;font:inherit}button{cursor:pointer;font-weight:650}button.primary{background:linear-gradient(100deg,#9333ea,#6d28d9);border:0}button:active{transform:translateY(1px)}.buttons{display:grid;grid-template-columns:1fr 1fr;gap:8px}.hint{font-size:12px;color:var(--muted)}.metrics{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;padding:12px 16px}.metric{padding:12px;background:#0a111d;border:1px solid var(--line);border-radius:12px}.metric b{display:block;font-size:18px}.metric span{color:var(--muted);font-size:11px}.footer{padding:12px 16px;border-top:1px solid var(--line);color:var(--muted);font-size:11px}
@media(max-width:900px){.layout{grid-template-columns:1fr;padding:10px}header{padding:14px}.view{min-height:240px}.view img{max-height:58vh}}
</style></head><body>
<header><div class="brand"><div class="logo">A</div><div><h1>AeroWash Vision <span style="color:#c084fc">/ CAMERA</span></h1><small>Captura · Zoom digital · Bordes lejanos</small></div></div><div class="status" id="status">● Conectando…</div></header>
<main class="layout"><section class="card"><div class="cardhead"><b id="viewtitle">Vista de cámara · RAW</b><span class="pill" id="resolution">Esperando imagen</span></div>
<div class="view"><img id="feed" alt="Vista de cámara AeroWash"><div class="overlay">AEROWASH VISION<br><span id="overlaytext">Procesando bordes…</span></div></div>
<div class="metrics"><div class="metric"><b id="edgepct">—</b><span>Píxeles de borde</span></div><div class="metric"><b id="fps">3 s</b><span>Actualización</span></div><div class="metric"><b id="zoommetric">1.0×</b><span>Zoom digital</span></div></div>
<div class="footer">La vista se refresca cada 0,7 segundos cuando el procesamiento lo permite. El zoom digital amplía una zona de la imagen; no sustituye un objetivo óptico ni recupera detalle que la cámara no capturó.</div></section>
<aside class="card"><div class="cardhead"><b>Controles de imagen</b><span class="pill">EN DIRECTO</span></div><div class="controls">
<div class="control"><div class="labelrow"><label for="source">Fuente</label></div><select id="source"><option value="raw">RAW · cámara original</option><option value="processed">FRAME · procesada</option></select></div>
<div class="control"><div class="labelrow"><label for="zoom">Zoom digital</label><span class="value" id="zoomval">1.0×</span></div><input id="zoom" type="range" min="1" max="4" step=".1" value="1"><div class="labelrow hint"><span>Encuadre completo</span><span>4× ampliación</span></div></div>
<div class="control"><div class="labelrow"><label for="sensitivity">Sensibilidad de bordes</label><span class="value" id="sensval">Alta</span></div><input id="sensitivity" type="range" min="1" max="4" step="1" value="2"><div class="hint">Más sensibilidad detecta bordes tenues y lejanos, pero también más ruido.</div></div>
<div class="control"><div class="labelrow"><label for="purple">Color de contorno</label></div><select id="purple"><option value="true">Morado intenso</option><option value="false">Ver bordes en blanco</option></select></div>
<div class="buttons"><button class="primary" id="apply">Aplicar ajustes</button><button id="reset">Restablecer</button></div>
<div class="control"><button id="snapshot">Guardar captura procesada</button><div class="hint" id="message">Esperando la primera imagen…</div></div>
<div class="hint"><b>Para detectar objetos más lejanos:</b> mejora la iluminación, usa una resolución mayor y acerca el sensor si es posible. La sensibilidad aumenta la detección de bordes de bajo contraste, pero no crea información que falte en la imagen.</div>
</div></aside></main>
<script>
const $=id=>document.getElementById(id);let timer=null;let busy=false;let lastUrl=null;
function read(){return {zoom:+$('zoom').value,sensitivity:+$('sensitivity').value,purple:$('purple').value==='true',source:$('source').value}}
function updateLabels(){$('zoomval').textContent=Number($('zoom').value).toFixed(1)+'×';$('zoommetric').textContent=Number($('zoom').value).toFixed(1)+'×';$('sensval').textContent=['','Muy alta','Alta','Media','Baja'][+$('sensitivity').value]}
async function refresh(){if(busy)return;busy=true;try{const s=read();const r=await fetch('/frame.jpg?'+new URLSearchParams(s),{cache:'no-store'});if(!r.ok)throw Error(await r.text());const blob=await r.blob();const nextUrl=URL.createObjectURL(blob);$('feed').src=nextUrl;if(lastUrl)URL.revokeObjectURL(lastUrl);lastUrl=nextUrl;const m=await fetch('/status?source='+s.source,{cache:'no-store'}).then(x=>x.json());$('status').textContent=m.ok?'● Cámara conectada':'● Esperando cámara';$('resolution').textContent=m.width?m.width+' × '+m.height:'Esperando imagen';$('edgepct').textContent='Activo';$('overlaytext').textContent='Bordes morados activos';$('message').textContent=m.file+' · '+m.age+' s desde actualización';$('viewtitle').textContent='Vista de cámara · '+s.source.toUpperCase()}catch(e){$('status').textContent='● Sin imagen';$('message').textContent=e.message}finally{busy=false}}
$('zoom').oninput=updateLabels;$('sensitivity').oninput=updateLabels;$('apply').onclick=refresh;$('source').onchange=refresh;$('purple').onchange=refresh;$('reset').onclick=()=>{$('zoom').value=1;$('sensitivity').value=2;$('purple').value='true';$('source').value='raw';updateLabels();refresh()};$('snapshot').onclick=async()=>{try{const s=read();const r=await fetch('/snapshot?'+new URLSearchParams(s),{method:'POST'});const j=await r.json();$('message').textContent=j.ok?'Guardado: '+j.path:j.error}catch(e){$('message').textContent=e.message}};updateLabels();refresh();timer=setInterval(refresh,700);
</script></body></html>"""

def build_frame(query):
    settings = {
        "zoom": max(1.0, min(4.0, float(query.get("zoom", ["1"])[0]))),
        "sensitivity": max(1, min(4, int(query.get("sensitivity", ["2"])[0]))),
        "purple": query.get("purple", ["true"])[0].lower() == "true",
        "source": "processed" if query.get("source", ["raw"])[0] == "processed" else "raw",
    }
    path = PROCESSED if settings["source"] == "processed" else RAW
    frame = cv2.imread(str(path))
    if frame is None:
        raise FileNotFoundError(f"No hay imagen en {path}. Comprueba que bot.py y la cámara estén activos.")
    h, w = frame.shape[:2]
    z = settings["zoom"]
    if z > 1:
        cw, ch = max(2, int(w / z)), max(2, int(h / z))
        x0, y0 = (w - cw) // 2, (h - ch) // 2
        frame = cv2.resize(frame[y0:y0+ch, x0:x0+cw], (w, h), interpolation=cv2.INTER_CUBIC)
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    gray = clahe.apply(gray)
    gray = cv2.bilateralFilter(gray, 5, 35, 35)
    # Sensitivity 1 is most sensitive; 4 is least sensitive.
    thresholds = {1:(10, 32), 2:(18, 48), 3:(32, 80), 4:(50, 125)}
    low, high = thresholds[settings["sensitivity"]]
    fine = cv2.Canny(gray, low, high, L2gradient=True)
    coarse = cv2.Canny(gray, max(12, low*2), high*2, L2gradient=True)
    edges = cv2.bitwise_or(fine, coarse)
    # Keep tiny connected components to preserve small distant details; only remove single-pixel speckle.
    n, labels, stats, _ = cv2.connectedComponentsWithStats((edges > 0).astype(np.uint8), 8)
    mask = np.zeros_like(edges)
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] >= 2:
            mask[labels == i] = 255
    if settings["purple"]:
        color = np.zeros_like(frame); color[:] = (255, 0, 255)
    else:
        color = np.full_like(frame, 255)
    out = frame.copy()
    active = mask > 0
    blended = cv2.addWeighted(frame, 0.18, color, 0.82, 0)
    out[active] = blended[active]
    ok, encoded = cv2.imencode(".jpg", out, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
    if not ok: raise RuntimeError("No se pudo codificar la imagen")
    return encoded.tobytes(), mask, (w, h), path.name

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = HTML.encode()
            self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
        if parsed.path == "/status":
            source = parse_qs(parsed.query).get("source", ["raw"])[0]
            path = PROCESSED if source == "processed" else RAW
            frame = cv2.imread(str(path), cv2.IMREAD_REDUCED_COLOR_2) if path.exists() else None
            age = round(time.time() - path.stat().st_mtime, 1) if path.exists() else None
            if frame is None:
                data = {"ok": False, "width": None, "height": None, "age": age, "file": path.name, "edge_percent": "—"}
            else:
                data = {"ok": True, "width": int(frame.shape[1]), "height": int(frame.shape[0]), "age": age, "file": path.name, "edge_percent": "—"}
            body = json.dumps(data).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if parsed.path == "/frame.jpg":
            try:
                data, mask, dims, name=build_frame(parse_qs(parsed.query))
                body=data; self.send_response(200); self.send_header("Content-Type","image/jpeg"); self.send_header("Cache-Control","no-store"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
            except Exception as e:
                body=str(e).encode(); self.send_response(503); self.send_header("Content-Type","text/plain; charset=utf-8"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        self.send_error(404)
    def do_POST(self):
        parsed=urlparse(self.path)
        if parsed.path=="/snapshot":
            try:
                data, mask, dims, name=build_frame(parse_qs(parsed.query))
                folder=ROOT/"dataset"/"camera_ui"; folder.mkdir(parents=True,exist_ok=True)
                stamp=__import__("time").strftime("%Y%m%d_%H%M%S")
                image_path=folder/f"{stamp}_overlay.jpg"; mask_path=folder/f"{stamp}_mask.png"
                image_path.write_bytes(data); cv2.imwrite(str(mask_path),mask)
                result={"ok":True,"path":str(image_path),"mask":str(mask_path)}
            except Exception as e: result={"ok":False,"error":str(e)}
            body=json.dumps(result).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
        self.send_error(404)

if __name__ == "__main__":
    print(f"AeroWash Vision Camera UI: http://{HOST}:{PORT}")
    print(f"RAW: {RAW}")
    print(f"FRAME: {PROCESSED}")
    print("Keep the camera capture process running. Press Ctrl+C to stop the dashboard.")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
