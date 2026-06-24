# GDAL image with Python bindings already installed.
# Use the "ubuntu-full" variant: it includes the Arrow/Parquet driver that the
# GeoParquet conversion needs (the "ubuntu-small" image does NOT have it).
FROM ghcr.io/osgeo/gdal:ubuntu-full-latest

# Add pip so we can install boto3 (the AWS SDK for Python).
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Build tippecanoe from source: it turns the layers into .pmtiles vector tiles.
# It is not packaged in apt, so we compile it, then drop the build toolchain to
# keep the image smaller (the runtime libs libsqlite3-0 / zlib1g stay, since GDAL
# depends on them).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git build-essential libsqlite3-dev zlib1g-dev \
    && git clone --depth 1 https://github.com/felt/tippecanoe.git /tmp/tippecanoe \
    && make -C /tmp/tippecanoe -j"$(nproc)" \
    && make -C /tmp/tippecanoe install \
    && rm -rf /tmp/tippecanoe \
    && apt-get purge -y --auto-remove git build-essential libsqlite3-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
# Ubuntu 24.04 marks the system Python as "externally managed" (PEP 668),
# so --break-system-packages is required to pip install into it.
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

COPY process_data.py .

ENTRYPOINT ["python3", "process_data.py"]
