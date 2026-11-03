import logging
import os

import azure.functions as func
import requests
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()
FEED = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/1.0_{}.geojson"


@app.timer_trigger(schedule="0 * * * * *", arg_name="timer", run_on_startup=True)
def ingest(timer: func.TimerRequest) -> None:
    container = BlobServiceClient.from_connection_string(
        os.environ["STORAGE_CONNECTION_STRING"]).get_container_client("quakes")
    for period in ("hour", "day", "week", "month"):
        try:
            r = requests.get(FEED.format(period), timeout=20)
            r.raise_for_status()
            container.upload_blob(f"1.0_{period}.geojson", r.content, overwrite=True)
        except Exception:
            logging.exception("Fallo la ingesta de %s", period)
