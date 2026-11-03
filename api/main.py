import json
import os
import time
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

FEED = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/1.0_{}.geojson"
CONTAINER = "quakes"
TTL = 30        # segundos de caché en memoria
MAX_AGE = 600   # edad máxima (s) del blob antes de considerarlo viejo

app = FastAPI(title="SismoWatch API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET"])
_cache = {}


def read_blob(period):
    conn = os.getenv("STORAGE_CONNECTION_STRING")
    if not conn:
        return None
    from azure.storage.blob import BlobClient
    stream = BlobClient.from_connection_string(
        conn, CONTAINER, f"1.0_{period}.geojson").download_blob()
    return json.loads(stream.readall()), stream.properties.last_modified


def fetch_usgs(period):
    r = httpx.get(FEED.format(period), timeout=10)
    r.raise_for_status()
    return r.json()


def load(period):
    hit = _cache.get(period)
    if hit and time.time() - hit[0] < TTL:
        return hit[1]
    result = stale = None
    try:
        blob = read_blob(period)
        if blob:
            data, modified = blob
            item = (data, "cache", modified.isoformat())
            if time.time() - modified.timestamp() <= MAX_AGE:
                result = item
            else:
                stale = (data, "cache-stale", modified.isoformat())
    except Exception:
        pass
    if result is None:
        try:
            result = (fetch_usgs(period), "usgs", datetime.now(timezone.utc).isoformat())
        except Exception:
            result = stale
    if result is None:
        raise HTTPException(503, "Sin datos disponibles")
    _cache[period] = (time.time(), result)
    return result


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/earthquakes")
def earthquakes(
    period: str = Query("day", pattern="^(hour|day|week|month)$"),
    min_mag: float = Query(2.5, ge=0, le=10),
):
    data, source, updated = load(period)
    feats = [f for f in data["features"] if (f["properties"].get("mag") or 0) >= min_mag]
    return {
        "type": "FeatureCollection",
        "features": feats,
        "metadata": {"source": source, "updated": updated, "count": len(feats)},
    }
