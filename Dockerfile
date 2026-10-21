# Debian 13 (trixie) ships ffmpeg 7.1 with every filter the pipeline uses
# (arnndn, afftdn, dynaudnorm, adynamicequalizer, loudnorm, alimiter, deesser).
FROM python:3.12-slim-trixie

ARG WITH_ASR=1
ENV PYTHONUNBUFFERED=1 \
    DATA_DIR=/data \
    HF_HOME=/data/hf-cache \
    PORT=8000

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# DeepFilterNet (neural speech denoiser) - official release binary for this architecture
ARG TARGETARCH
ARG DF_VERSION=0.5.6
RUN case "$TARGETARCH" in \
      arm64) T=aarch64-unknown-linux-gnu ;; \
      *)     T=x86_64-unknown-linux-musl ;; \
    esac \
 && python -c "import urllib.request,sys; urllib.request.urlretrieve(sys.argv[1], '/usr/local/bin/deep-filter')" \
      "https://github.com/Rikorose/DeepFilterNet/releases/download/v${DF_VERSION}/deep-filter-${DF_VERSION}-$T" \
 && chmod +x /usr/local/bin/deep-filter && deep-filter --version

WORKDIR /srv
COPY requirements.txt requirements-asr.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
 && if [ "$WITH_ASR" = "1" ]; then pip install --no-cache-dir -r requirements-asr.txt; fi

COPY app ./app
# RNNoise model (fallback denoiser)
RUN mkdir -p models && python -c "import urllib.request; urllib.request.urlretrieve('https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn', 'models/std.rnnn')"

VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request,os; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/healthz')"
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --proxy-headers --forwarded-allow-ips='*'"]
