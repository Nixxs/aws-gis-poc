"""POC data pipeline - File Geodatabase -> GeoParquet + PMTiles.

This runs inside the AWS Batch (Fargate) container. It:
  1. Downloads the contents of the ingestion bucket to local disk.
  2. Finds any File Geodatabase (.gdb) in what was downloaded.
  3. Reads every feature class (a layer that has geometry) in each .gdb.
  4. Converts each feature class to a GeoParquet file using GDAL.
  5. Converts each feature class to a PMTiles vector tileset using tippecanoe.
  6. Uploads the GeoParquet and PMTiles files to the application bucket.
  7. Optionally deletes the processed source objects from the ingestion bucket.

Requires a GDAL build with the Parquet driver and the tippecanoe binary on PATH
(both provided by this project's Dockerfile, built on osgeo/gdal "ubuntu-full").

Configuration comes from environment variables (set on the Batch job):
    INGESTION_BUCKET           (required)  source S3 bucket (where the .gdb is uploaded)
    APP_BUCKET                 (required)  destination S3 bucket
    SOURCE_PREFIX              (optional)  only process objects under this prefix (default: "")
    GEOPARQUET_PREFIX          (optional)  prefix to write GeoParquet under (default: "geoparquet/")
    PMTILES_PREFIX             (optional)  prefix to write PMTiles under (default: "pmtiles/")
    MAKE_PMTILES               (optional)  "true"/"false" - generate PMTiles too (default: "true")
    TIPPECANOE_ARGS            (optional)  extra tippecanoe flags (default: see below)
    DELETE_SOURCE_AFTER_COPY   (optional)  "true"/"false" - delete processed source objects from the
                                           ingestion bucket once conversion succeeds (default: "true")
"""

import logging
import os
import subprocess
import sys
import tempfile

import boto3
from osgeo import gdal, ogr

# Default tippecanoe flags: guess a sensible zoom range and thin dense areas so
# the tileset stays a reasonable size. Override with the TIPPECANOE_ARGS env var.
DEFAULT_TIPPECANOE_ARGS = "-zg --drop-densest-as-needed --extend-zooms-if-still-dropping"

# Make GDAL raise Python exceptions on error instead of returning None silently.
gdal.UseExceptions()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("process_data")


def get_env(name: str, default: str = "", required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        log.error("Missing required environment variable: %s", name)
        sys.exit(1)
    return value


def delete_source_objects(s3, bucket: str, keys: list) -> None:
    """Delete the given keys from the ingestion bucket in batches of 1000."""
    for start in range(0, len(keys), 1000):
        chunk = keys[start:start + 1000]
        response = s3.delete_objects(
            Bucket=bucket,
            Delete={"Objects": [{"Key": k} for k in chunk], "Quiet": True},
        )
        errors = response.get("Errors", [])
        if errors:
            for err in errors:
                log.error("Failed to delete %s: %s", err.get("Key"), err.get("Message"))
            raise RuntimeError(f"Failed to delete {len(errors)} object(s) from s3://{bucket}")
    log.info("Cleared %d object(s) from ingestion bucket s3://%s", len(keys), bucket)


def download_prefix(s3, bucket: str, prefix: str, dest_dir: str) -> list:
    """Download every object under prefix to dest_dir, preserving key paths.

    Returns the list of source keys that were downloaded.
    """
    paginator = s3.get_paginator("list_objects_v2")
    keys = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/"):
                continue  # skip "folder" placeholder objects
            local_path = os.path.join(dest_dir, key.replace("/", os.sep))
            os.makedirs(os.path.dirname(local_path), exist_ok=True)
            s3.download_file(bucket, key, local_path)
            keys.append(key)
    return keys


def find_geodatabases(root: str) -> list:
    """Find every File Geodatabase (a directory ending in .gdb) under root."""
    found = []
    for dirpath, dirnames, _ in os.walk(root):
        for name in dirnames:
            if name.lower().endswith(".gdb"):
                found.append(os.path.join(dirpath, name))
    return found


def list_feature_classes(gdb_path: str) -> list:
    """Return the names of feature classes (layers that have geometry) in a .gdb."""
    datasource = ogr.Open(gdb_path)
    if datasource is None:
        raise RuntimeError(f"GDAL could not open geodatabase: {gdb_path}")
    names = []
    for i in range(datasource.GetLayerCount()):
        layer = datasource.GetLayer(i)
        if layer.GetGeomType() != ogr.wkbNone:
            names.append(layer.GetName())
        else:
            log.info("Skipping non-spatial table '%s'", layer.GetName())
    datasource = None  # close the datasource
    return names


def convert_layer_to_parquet(gdb_path: str, layer_name: str, out_path: str) -> None:
    """Convert a single feature class to a GeoParquet file using GDAL."""
    gdal.VectorTranslate(
        out_path,
        gdb_path,
        options=gdal.VectorTranslateOptions(format="Parquet", layers=[layer_name]),
    )


def convert_layer_to_geojson(gdb_path: str, layer_name: str, out_path: str) -> None:
    """Export a feature class to GeoJSON in EPSG:4326 (what tippecanoe expects)."""
    gdal.VectorTranslate(
        out_path,
        gdb_path,
        options=gdal.VectorTranslateOptions(
            format="GeoJSON",
            layers=[layer_name],
            dstSRS="EPSG:4326",
            reproject=True,
        ),
    )


def convert_geojson_to_pmtiles(
    geojson_path: str, layer_name: str, out_path: str, extra_args: list
) -> None:
    """Build a PMTiles vector tileset from GeoJSON using tippecanoe."""
    cmd = [
        "tippecanoe",
        "-o", out_path,
        "-l", layer_name,
        "--force",
        *extra_args,
        geojson_path,
    ]
    log.info("Running tippecanoe: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ingestion_bucket = get_env("INGESTION_BUCKET", required=True)
    app_bucket = get_env("APP_BUCKET", required=True)
    source_prefix = get_env("SOURCE_PREFIX", default="")
    geoparquet_prefix = get_env("GEOPARQUET_PREFIX", default="geoparquet/")
    pmtiles_prefix = get_env("PMTILES_PREFIX", default="pmtiles/")
    make_pmtiles = get_env("MAKE_PMTILES", default="true").lower() == "true"
    tippecanoe_args = get_env("TIPPECANOE_ARGS", default=DEFAULT_TIPPECANOE_ARGS).split()
    delete_after_copy = get_env("DELETE_SOURCE_AFTER_COPY", default="true").lower() == "true"

    s3 = boto3.client("s3")
    work_dir = tempfile.mkdtemp(prefix="gisproc_")
    ingest_dir = os.path.join(work_dir, "ingest")
    out_dir = os.path.join(work_dir, "out")
    os.makedirs(out_dir, exist_ok=True)

    log.info("Downloading s3://%s/%s -> %s", ingestion_bucket, source_prefix, ingest_dir)
    source_keys = download_prefix(s3, ingestion_bucket, source_prefix, ingest_dir)
    if not source_keys:
        log.warning("No objects found under s3://%s/%s; nothing to do.", ingestion_bucket, source_prefix)
        return

    # Locate the config.json that triggered this run (uploaded alongside the GDB).
    # It is published to the app bucket root at the end so the frontend can read it.
    config_local = None
    for key in source_keys:
        if os.path.basename(key) == "config.json":
            config_local = os.path.join(ingest_dir, key.replace("/", os.sep))
            break
    if config_local is None:
        log.warning("No config.json found in the ingestion upload; the hosted frontend config will not be updated.")

    geodatabases = find_geodatabases(ingest_dir)
    if not geodatabases:
        log.warning("No .gdb found in the downloaded data; nothing to convert.")
        return
    log.info(
        "Found %d geodatabase(s): %s",
        len(geodatabases),
        ", ".join(os.path.basename(g) for g in geodatabases),
    )

    uploaded = 0
    for gdb_path in geodatabases:
        gdb_stem = os.path.splitext(os.path.basename(gdb_path))[0]
        feature_classes = list_feature_classes(gdb_path)
        if not feature_classes:
            log.warning("No feature classes (layers with geometry) in %s", gdb_path)
            continue
        log.info(
            "%s has %d feature class(es): %s",
            os.path.basename(gdb_path),
            len(feature_classes),
            ", ".join(feature_classes),
        )

        for fc in feature_classes:
            out_path = os.path.join(out_dir, f"{gdb_stem}__{fc}.parquet")
            log.info("Converting feature class '%s' -> GeoParquet", fc)
            convert_layer_to_parquet(gdb_path, fc, out_path)

            parquet_key = f"{geoparquet_prefix}{fc}.parquet"
            log.info("Uploading -> s3://%s/%s", app_bucket, parquet_key)
            s3.upload_file(out_path, app_bucket, parquet_key)
            uploaded += 1

            if make_pmtiles:
                geojson_path = os.path.join(out_dir, f"{gdb_stem}__{fc}.geojson")
                log.info("Exporting feature class '%s' -> GeoJSON (EPSG:4326)", fc)
                convert_layer_to_geojson(gdb_path, fc, geojson_path)

                pmtiles_path = os.path.join(out_dir, f"{gdb_stem}__{fc}.pmtiles")
                log.info("Converting feature class '%s' -> PMTiles", fc)
                convert_geojson_to_pmtiles(geojson_path, fc, pmtiles_path, tippecanoe_args)

                pm_key = f"{pmtiles_prefix}{fc}.pmtiles"
                log.info("Uploading -> s3://%s/%s", app_bucket, pm_key)
                s3.upload_file(
                    pmtiles_path,
                    app_bucket,
                    pm_key,
                    ExtraArgs={"ContentType": "application/vnd.pmtiles"},
                )
                uploaded += 1

    if uploaded == 0:
        log.warning("No feature classes were converted.")
        return

    log.info("Done. Wrote %d output file(s) to s3://%s", uploaded, app_bucket)

    # Publish the config.json to the app bucket root so the frontend can fetch it.
    if config_local and os.path.exists(config_local):
        log.info("Publishing config -> s3://%s/config.json", app_bucket)
        s3.upload_file(
            config_local,
            app_bucket,
            "config.json",
            ExtraArgs={"ContentType": "application/json"},
        )

    # Only reached if every conversion + upload above succeeded (any failure
    # raises and fails the job first), so it is safe to remove the sources now.
    if delete_after_copy:
        delete_source_objects(s3, ingestion_bucket, source_keys)
    else:
        log.info("DELETE_SOURCE_AFTER_COPY is disabled; leaving ingestion bucket untouched.")


if __name__ == "__main__":
    main()
