# GDAL image with Python bindings already installed.
# Use the "ubuntu-full" variant: it includes the Arrow/Parquet driver that the
# GeoParquet conversion needs (the "ubuntu-small" image does NOT have it).
FROM ghcr.io/osgeo/gdal:ubuntu-full-latest

# Add pip so we can install boto3 (the AWS SDK for Python).
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
# Ubuntu 24.04 marks the system Python as "externally managed" (PEP 668),
# so --break-system-packages is required to pip install into it.
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

COPY process_data.py .

ENTRYPOINT ["python3", "process_data.py"]
