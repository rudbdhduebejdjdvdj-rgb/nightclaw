# AeroWash Vision: cámara rápida y entrenamiento local

## 1. Actualizar los archivos en el Mac

En Terminal:

```bash
cd ~/AeroWashVision
curl -L "https://raw.githubusercontent.com/rudbdhduebejdjdvdj-rgb/nightclaw/aerowash-mcp-server/camera_dashboard.py" -o camera_dashboard.py
curl -L "https://raw.githubusercontent.com/rudbdhduebejdjdvdj-rgb/nightclaw/aerowash-mcp-server/train_edge_model.py" -o train_edge_model.py
```

Instala las dependencias de entrenamiento dentro del entorno virtual:

```bash
source .venv/bin/activate
python -m pip install -r requirements-ai.txt
```

## 2. Arrancar cámara y panel

Mantén ejecutándose el proceso que captura la cámara (por ejemplo, el proceso de captura que ya usas). En otra pestaña de Terminal:

```bash
cd ~/AeroWashVision
source .venv/bin/activate
python camera_dashboard.py
```

Abre http://127.0.0.1:8765. El panel solicita imágenes cada 0,7 s, evita peticiones concurrentes y ya no recalcula los bordes al consultar el estado. El procesamiento de cada imagen sigue dependiendo de la resolución y la potencia del Mac; si la imagen tarda más, la interfaz no apila solicitudes.

Si el panel dice que no encuentra archivos, comprueba que el proceso de captura actualiza:
- `dataset/connector/latest_raw.jpg`
- `dataset/connector/latest.jpg`

La interfaz procesa los archivos existentes, no inicia la cámara por sí sola.

## 3. Preparar un dataset de entrenamiento válido

Crea esta estructura:

```text
~/AeroWashVision/dataset/edge_training/
├── images/
│   ├── habitacion_001.jpg
│   └── ...
└── masks/
    ├── habitacion_001.png
    └── ...
```

Cada máscara PNG debe tener exactamente el mismo nombre base que la imagen correspondiente; blanco = borde, negro = fondo. **Revisa y corrige las máscaras antes de entrenar.** Las máscaras automáticas de Canny son etiquetas provisionales y enseñarían al modelo a imitar ese algoritmo, no necesariamente a reconocer todos los bordes reales. No mezcles capturas y máscaras distintas.

Empieza con al menos 100 pares variados, con diferentes distancias, iluminación y texturas. Con menos pares, el modelo puede sobreajustarse.

## 4. Entrenar

```bash
cd ~/AeroWashVision
source .venv/bin/activate
python train_edge_model.py --epochs 30 --batch-size 4 --size 320
```

El modelo se guarda en `~/AeroWashVision/models/aerowash_edges.pt`. El script usa MPS en Mac compatible, CUDA si está disponible, o CPU. El entrenamiento requiere PyTorch y no llama a ninguna API de pago.

## Importante

El entrenamiento aún no se ejecuta automáticamente al abrir la cámara. Debes recopilar y revisar imágenes/máscaras primero. Este modelo detecta bordes; no reconoce suciedad ni certifica que sea seguro usarlo para controlar un dron. Valídalo con imágenes independientes antes de cualquier uso operativo.
