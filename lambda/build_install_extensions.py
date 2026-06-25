"""Build-time helper: pre-install the DuckDB extensions used to read parquet
from S3 into a directory baked into the image.

Loading them from the image at runtime (rather than INSTALL-ing on first use)
removes a network dependency and latency spike from Lambda cold starts.
"""

import os

import duckdb

ext_dir = os.environ.get("DUCKDB_EXTENSION_DIR", "/opt/duckdb_extensions")
os.makedirs(ext_dir, exist_ok=True)

con = duckdb.connect()
con.execute(f"SET extension_directory='{ext_dir}'")
for ext in ("httpfs", "aws"):
    con.execute(f"INSTALL {ext}")
con.close()

print(f"installed duckdb extensions (httpfs, aws) into {ext_dir}")
