# OpenPhonic

Post-produzione audio automatica, self-hosted. Carichi un file audio o video, scegli un preset,
e ottieni una voce pulita, livellata e alla loudness giusta per podcast, YouTube, radio o audiolibri.
Stesse funzioni di [Auphonic](https://auphonic.com), ma gira sul tuo computer o sul tuo server:
nessun file lascia la tua macchina.

Interfaccia web in italiano, API REST, nessun account esterno.

---

## Indice

1. [Cosa fa](#cosa-fa)
2. [Come lavora sulla voce](#come-lavora-sulla-voce)
3. [Risultati misurati](#risultati-misurati)
4. [Installazione locale](#installazione-locale)
5. [Uso dall'interfaccia](#uso-dallinterfaccia)
6. [API REST](#api-rest)
7. [Impostazioni](#impostazioni)
8. [Metterla online](#metterla-online)
9. [Variabili d'ambiente](#variabili-dambiente)
10. [Struttura del progetto](#struttura-del-progetto)
11. [Limiti noti](#limiti-noti)
12. [Componenti di terze parti](#componenti-di-terze-parti)

---

## Cosa fa

| Funzione | Come è fatta |
|---|---|
| **Riduzione rumore AI** | [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet), rete neurale che separa la voce da rumore di fondo, ventole, traffico e parte del riverbero. La quantità si sceglie da sola in base al rapporto segnale/rumore misurato. Alternative: RNNoise e riduzione spettrale classica. |
| **Adaptive Leveler** | Bilancia il volume frase per frase, come un tecnico al fader. Nelle pause il guadagno resta fermo: il rumore di fondo non viene mai alzato. |
| **Voice AutoEQ** | Corregge con delicatezza (massimo ±4 dB) il timbro della voce verso lo spettro medio del parlato umano: meno rimbombo, più presenza. |
| **Filtri** | Passa-alto contro rombi e vibrazioni, rilevamento automatico del ronzio elettrico a 50/60 Hz e rimozione delle armoniche, de-esser per le sibilanti, de-plosive per P e B. |
| **Loudness** | Normalizzazione EBU R128 / ITU-R BS.1770 a −23, −19, −18, −16 o −14 LUFS, con limitatore true-peak e oversampling 4×. Opzione dual mono. |
| **Taglio pause** | Accorcia i silenzi lunghi lasciando una pausa naturale, con soglia adattiva e dissolvenze di 10 ms a ogni taglio (niente click). |
| **Taglio parole riempitive** | Trova ehm, uhm, ah, mh… con Whisper e li rimuove. |
| **Trascrizione** | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) in locale: TXT, sottotitoli SRT e VTT, JSON con ogni parola e il suo tempo. |
| **Multitraccia** | Ogni voce viene trattata separatamente, poi mixata; la musica sta 8 LU sotto il parlato e si abbassa da sola quando qualcuno parla (ducking). |
| **Intro e outro** | Aggiunti in testa e in coda e normalizzati insieme al resto. |
| **Video** | Accetta MP4/MOV: l'audio elaborato torna nel video. Se ci sono tagli, il video viene tagliato negli stessi punti e resta sincronizzato. |
| **Formati in uscita** | MP3, AAC (M4A), Opus, Ogg Vorbis, FLAC, WAV 24 bit, MP4. Più formati nella stessa produzione. |
| **Metadati** | Titolo, autore, album, anno, genere, descrizione, copertina incorporata, capitoli (spostati in automatico dopo tagli e intro). |
| **Statistiche** | Prima e dopo: loudness, true peak, loudness range, rumore di fondo, SNR, durata. Forme d'onda, spettrogrammi e ascolto A/B sincronizzato. |
| **Preset** | Podcast, broadcast EBU, YouTube/Spotify, audiolibro ACX, intervista difficile, musica, più quelli che salvi tu. |
| **Rielaborazione** | Stessi file, nuove impostazioni, senza ricaricare nulla. |
| **API REST** | Tutto quello che fa l'interfaccia, con documentazione interattiva su `/docs`. |

---

## Come lavora sulla voce

Ogni traccia di parlato attraversa questa catena, nell'ordine:

```
ingresso (audio o video, qualsiasi formato)
  │
  ├─ analisi: rumore di fondo, SNR, ronzio 50/60 Hz, loudness, picchi
  │
  ├─ 1. voce in mono + passa-alto 75 Hz + notch sul ronzio (se trovato) + de-plosive
  ├─ 2. riduzione rumore DeepFilterNet (attenuazione scelta dal SNR)
  ├─ 3. Voice AutoEQ + de-esser
  ├─ 4. Adaptive Leveler (guadagno per frase, fermo nelle pause)
  ├─ 5. compressore leggero, soglia relativa al livello della voce
  │
  ├─ mix multitraccia con ducking della musica
  ├─ trascrizione Whisper (se richiesta)
  ├─ taglio pause e riempitivi, con dissolvenze
  ├─ intro + outro
  ├─ loudness: guadagno lineare + limitatore true-peak, ripetuto finché è entro 0,2 LU
  │
  └─ codifica in tutti i formati, con metadati, copertina e capitoli
```

Le scelte che fanno la differenza:

- **Prima si pulisce, poi si livella.** Il leveler lavora su una voce già senza rumore, quindi alzare una frase detta piano non alza anche il fondo.
- **Il leveler non è un AGC.** Misura la loudness solo dove c'è parlato (finestre di 400 ms), calcola il guadagno per ogni frase e lo leviga in avanti e all'indietro (fase zero, circa 0,6 s). Nelle pause il guadagno è interpolato tra la frase prima e quella dopo. Niente "respiro" del rumore, niente pompaggio.
- **Nessun gate.** Un noise gate fa sparire e ricomparire il fondo tra una frase e l'altra, ed è la cosa che più fa suonare amatoriale una registrazione. Qui il fondo, quel poco che resta, è costante.
- **AutoEQ prudente.** Si sposta solo una parte della distanza dalla curva LTASS (lo spettro medio del parlato, Byrne et al. 1994), non si alzano mai i bassi e la correzione non supera ±4 dB.
- **Loudness esatta.** Il filtro `loudnorm` di ffmpeg, quando non riesce a rispettare il true peak, passa in modalità dinamica e manca il bersaglio. Qui si applica un guadagno lineare, poi un limitatore true-peak a 192 kHz, e si rimisura finché il risultato è entro 0,2 LU.

---

## Risultati misurati

Registrazione reale: video iPhone, una voce in una stanza con rumore di fondo forte tra 150 e 600 Hz, 2 minuti e 13 secondi.

| | Originale | Dopo OpenPhonic |
|---|---|---|
| Voce sopra il rumore (300–600 Hz) | 16 dB | 47 dB |
| Rapporto segnale/rumore | 14 dB | 49 dB |
| Loudness integrata | −24,7 LUFS | −16,0 LUFS |
| True peak | −5,1 dBTP | −1,2 dBTP |
| Loudness range | 7,6 LU | 5,5 LU |
| Tempo di elaborazione (Mac Apple Silicon) | | 34 s |

Lo spettrogramma dopo l'elaborazione mostra parlato pulito su un fondo basso e uniforme, senza buchi.

---

## Installazione locale

Requisiti: **ffmpeg 7 o successivo**, **[uv](https://docs.astral.sh/uv/)**, macOS o Linux.

```bash
git clone https://github.com/giuseppelupo1979/openphonic.git
cd openphonic
./scripts/setup.sh
.venv/bin/uvicorn app.main:app --port 8765
```

Poi apri http://localhost:8765.

`setup.sh` crea l'ambiente Python 3.12, installa le dipendenze, scarica il binario di DeepFilterNet
adatto al tuo sistema in `bin/` e il modello RNNoise in `models/`. Senza riconoscimento vocale
(installazione più leggera): `WITH_ASR=0 ./scripts/setup.sh`.

Al primo uso della trascrizione Whisper scarica il modello scelto (base ≈ 150 MB, small ≈ 500 MB,
large-v3 ≈ 3 GB).

---

## Uso dall'interfaccia

1. **Nuova produzione**: trascina un file audio o video. Scegli *Singola traccia*, *Multitraccia* (una voce per file, più eventuale musica) o *Da URL*.
2. Scegli un **preset**, oppure regola i singoli algoritmi. Ogni sezione si attiva e disattiva con il suo interruttore.
3. Facoltativo: intro, outro, copertina, metadati, capitoli (`00:00:00` + titolo).
4. Scegli uno o più **formati in uscita**.
5. **Avvia produzione**. La pagina mostra l'avanzamento passo per passo.
6. Alla fine: ascolto A/B (clicca sulle forme d'onda per saltare in un punto), statistiche, spettrogrammi, cosa è stato fatto, download, trascrizione cliccabile.
7. **Modifica e rielabora** riapre le impostazioni sugli stessi file.

Le impostazioni che usi spesso si salvano con **Salva come preset**.

---

## API REST

Se il server ha una password: `-u qualsiasi:PASSWORD` oppure `-H "Authorization: Bearer PASSWORD"`.
Documentazione interattiva su `/docs`.

| Metodo | Percorso | Cosa fa |
|---|---|---|
| `POST` | `/api/productions` | Crea una produzione (multipart: `tracks`, `intro`, `outro`, `cover`, `url`, `title`, `settings` JSON) |
| `GET` | `/api/productions` | Elenco produzioni |
| `GET` | `/api/productions/{id}` | Stato, avanzamento e risultato |
| `POST` | `/api/productions/{id}/reprocess` | Rielabora con nuove impostazioni (`{"settings": {...}}`) |
| `DELETE` | `/api/productions/{id}` | Elimina produzione e file |
| `GET` | `/api/productions/{id}/files/{nome}` | Scarica un file prodotto |
| `GET` | `/api/presets` | Preset predefiniti e salvati |
| `POST` | `/api/presets` | Salva un preset (`{"name", "settings"}`) |
| `DELETE` | `/api/presets/{nome}` | Elimina un preset |
| `GET` | `/api/capabilities` | Funzioni disponibili sul server e impostazioni predefinite |
| `GET` | `/healthz` | Health check (senza password) |

Esempio completo:

```bash
curl -X POST http://localhost:8765/api/productions \
  -F tracks=@episodio.wav \
  -F cover=@copertina.jpg \
  -F 'settings={
        "loudness": {"target": -16},
        "cutting": {"silence": true, "fillers": true},
        "speech": {"enabled": true, "language": "it", "model": "small"},
        "metadata": {"title": "Episodio 12", "artist": "Giuseppe Lupo"},
        "chapters": [{"start": "00:00:00", "title": "Apertura"}],
        "outputs": [{"format": "mp3", "bitrate": 128}, {"format": "flac"}]
      }'

curl http://localhost:8765/api/productions/ID
curl -O http://localhost:8765/api/productions/ID/files/Episodio_12.mp3
```

Multitraccia: più campi `tracks` e i ruoli in `settings.tracks`, nello stesso ordine:

```bash
curl -X POST http://localhost:8765/api/productions \
  -F tracks=@voce1.wav -F tracks=@voce2.wav -F tracks=@musica.mp3 \
  -F 'settings={"tracks":[{"role":"speech"},{"role":"speech"},{"role":"music"}],"ducking":true}'
```

---

## Impostazioni

Tutti i campi sono facoltativi: quelli mancanti prendono il valore predefinito (tra parentesi).

| Sezione | Campo | Valori |
|---|---|---|
| `leveler` | `enabled` (true), `strength` (100), `compressor` (auto) | strength 0–100; compressor `auto`, `soft`, `medium`, `hard`, `off` |
| `filtering` | `enabled` (true), `highpass` (auto), `hum` (auto), `autoeq` (true), `deesser` (false), `deplosive` (false) | highpass `auto`, `off`, `60`, `80`, `100`, `120`; hum `auto`, `off`, `50`, `60` |
| `denoise` | `enabled` (true), `method` (ai), `amount` (auto) | method `ai`, `rnnoise`, `classic`; amount `auto`, `low`, `medium`, `high`, `max` |
| `loudness` | `enabled` (true), `target` (−16), `true_peak` (−1), `dual_mono` (false) | target da −31 a −5 LUFS; true_peak da −6 a 0 dBTP |
| `cutting` | `silence` (false), `min_silence` (1.0), `keep_silence` (0.4), `silence_threshold_db` (adattiva), `fillers` (false) | secondi; soglia in dBFS |
| `speech` | `enabled` (false), `language` (auto), `model` (base) | lingua ISO (`it`, `en`…); model `tiny`, `base`, `small`, `medium`, `large-v3` |
| `outputs` | lista di `{format, bitrate, channels, sample_rate}` | format `mp3`, `aac`, `opus`, `ogg`, `flac`, `wav`, `video`; channels `keep`, `mono`, `stereo`; sample_rate 0 (48 kHz), 44100, 22050 |
| `metadata` | `title`, `artist`, `album`, `year`, `genre`, `comment`, `track` | testo |
| `chapters` | lista di `{start, title}` | start `HH:MM:SS` o secondi, sul file originale |
| `tracks` | lista di `{role}` | `speech` o `music` (per una traccia singola indica il tipo di contenuto) |
| | `ducking` (true), `ducking_amount_db` (−12) | multitraccia |

---

## Metterla online

L'app è pensata per girare in un container. **Imposta sempre `APP_PASSWORD`** quando è raggiungibile
da internet: senza, chiunque abbia l'indirizzo può usarla.

### Docker Compose (qualsiasi server Linux)

```bash
echo "APP_PASSWORD=una-password-lunga" > .env
docker compose up -d --build
```

Il Dockerfile (Debian 13, ffmpeg 7.1) scarica da solo DeepFilterNet per l'architettura del server e il
modello RNNoise. Le produzioni restano nel volume `/data`.

### Fly.io

```bash
fly launch --copy-config --no-deploy
fly volumes create openphonic_data --size 10
fly secrets set APP_PASSWORD=una-password-lunga
fly deploy
```

### Render

Il file `render.yaml` è un Blueprint: su Render scegli *New → Blueprint* e collega il repository.
La password viene generata in automatico (variabile `APP_PASSWORD` nel pannello).

### Sotto un percorso (reverse proxy)

Per servirla in `https://esempio.com/openphonic/` con un proxy che toglie il prefisso
(Caddy `handle_path /openphonic/*`, nginx `location /openphonic/ { proxy_pass http://app:8000/; }`),
imposta `ROOT_PATH=/openphonic`. L'interfaccia usa solo indirizzi relativi.

### Risorse

Con Whisper attivo servono circa **1,5 GB di RAM**. Su server piccoli usa `WORKERS=1` e il modello
`base` o `small`. DeepFilterNet elabora circa 20 volte più veloce del tempo reale su un Mac
Apple Silicon; su una CPU virtuale condivisa conta 5–10 volte.

---

## Variabili d'ambiente

| Variabile | Default | Cosa fa |
|---|---|---|
| `APP_PASSWORD` | vuota | Protegge interfaccia e API (HTTP Basic con qualsiasi utente, o Bearer). Vuota = app aperta |
| `WORKERS` | 2 | Produzioni elaborate in parallelo |
| `MAX_UPLOAD_MB` | 2000 | Dimensione massima di un file caricato |
| `RETENTION_DAYS` | 0 | Elimina le produzioni concluse più vecchie di N giorni (0 = mai) |
| `DATA_DIR` | `./data` (`/data` nel container) | Dove vivono produzioni e preset |
| `ROOT_PATH` | vuota | Prefisso pubblico se servita sotto un percorso |
| `HF_HOME` | cache utente (`/data/hf-cache` nel container) | Dove Whisper salva i modelli |
| `DEEPFILTER_BIN` | ricerca automatica | Percorso del binario `deep-filter` |
| `ALLOW_PRIVATE_URLS` | vuota | Con `1` l'input da URL può raggiungere indirizzi di rete interni (bloccati di default) |

---

## Struttura del progetto

```
app/
  main.py         API FastAPI, password, file statici
  jobs.py         produzioni su disco, coda di lavoro, preset, download da URL, pulizia
  pipeline.py     la catena di elaborazione completa
  leveler.py      rilevamento voce, Adaptive Leveler, Voice AutoEQ, guadagno in streaming
  analysis.py     rumore di fondo, SNR, ronzio, forme d'onda, pause
  transcribe.py   Whisper, parole riempitive, SRT/VTT/TXT/JSON
  ffmpeg.py       chiamate a ffmpeg/ffprobe, misure di loudness
  settings.py     modello delle impostazioni e preset predefiniti
  static/         interfaccia web (HTML, CSS, JavaScript senza build)
scripts/setup.sh  installazione locale
Dockerfile, docker-compose.yml, fly.toml, render.yaml
```

I file elaborati non passano mai da servizi esterni: ffmpeg, DeepFilterNet e Whisper girano in locale.
L'unica connessione in uscita è il download dei modelli al primo avvio.

---

## Limiti noti

- La catena è stata tarata su pochi file: una registrazione reale da iPhone e alcuni file sintetici. Su microfoni e stanze molto diversi può servire regolare intensità del leveler e quantità di riduzione rumore.
- Whisper a volte non trascrive le parole riempitive: il loro taglio non trova sempre tutto.
- L'immagine Docker è scritta ma non ancora provata con una build reale.
- Un'unica password condivisa, nessun account utente.
- Il riverbero viene ridotto solo in parte (da DeepFilterNet); non c'è un de-reverb dedicato.
- La copertina viene incorporata in MP3, M4A e FLAC; Opus, Ogg e WAV non la ricevono.

---

## Componenti di terze parti

| Componente | Uso | Licenza |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | decodifica, filtri, codifica | LGPL/GPL (installato a parte) |
| [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) | riduzione rumore AI | MIT / Apache 2.0 (scaricato da `setup.sh` e dal Dockerfile) |
| [RNNoise](https://github.com/xiph/rnnoise) + [modelli di GregorR](https://github.com/GregorR/rnnoise-models) | riduzione rumore alternativa | filtro BSD in ffmpeg; il modello è scaricato, non incluso |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | trascrizione | MIT |
| [FastAPI](https://fastapi.tiangolo.com), [NumPy](https://numpy.org) | server, calcolo | MIT, BSD |

OpenPhonic non è affiliato ad Auphonic.
