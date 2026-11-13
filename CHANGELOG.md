# Novità

Le versioni si leggono dall'alto: la prima è la più recente. Il numero è lo stesso per le app Mac,
Windows e la web app (file `VERSION`).

## 1.1.0

- Aggiornamento automatico: le app per Mac e Windows controllano all'avvio se su GitHub c'è una
  versione nuova, la scaricano, ne verificano l'impronta SHA-256 e si sostituiscono da sole.
  La web app mostra un avviso con le novità e il comando per aggiornare.
- Licenza MIT, repository pubblico.

**Download**

- `OpenPhonic-win-x64.zip`: Windows 10/11 su PC Intel o AMD. Estrai lo zip e fai doppio clic su
  "Installa OpenPhonic".
- `OpenPhonic-win-arm64.zip`: Windows 11 su PC ARM (Snapdragon, Parallels su Mac).
- `OpenPhonic-macos.zip`: macOS 26 su Apple Silicon, serve `brew install ffmpeg`. L'app non è
  notarizzata: al primo avvio clic destro, Apri.
- Ogni file ha il suo `.sha256` per verificarne l'integrità.

Gli zip per Windows includono FFmpeg 9.0 (licenza GPL v3, testo in `app\tools\ffmpeg-LICENSE.txt`),
compilato da [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds); il sorgente è su
[ffmpeg.org](https://ffmpeg.org/download.html) e nel repository BtbN.

## 1.0.0

- Prima versione: app per Mac (SwiftUI), app per Windows 11 (WPF) e web app (FastAPI), con lo stesso
  motore audio: riduzione rumore AI (DeepFilterNet), Adaptive Leveler, Voice AutoEQ, filtri, loudness
  EBU R128 esatta, taglio di pause e riempitivi, trascrizione e sottotitoli, video, preset.
