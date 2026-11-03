import pytest
from fastapi.testclient import TestClient

import main

SAMPLE = {"type": "FeatureCollection", "features": [
    {"properties": {"mag": 1.2}, "geometry": {"coordinates": [0, 0, 5]}},
    {"properties": {"mag": 3.1}, "geometry": {"coordinates": [1, 1, 10]}},
    {"properties": {"mag": None}, "geometry": {"coordinates": [2, 2, 1]}},
]}


@pytest.fixture(autouse=True)
def limpiar():
    main._cache.clear()


def test_health():
    assert TestClient(main.app).get("/health").json() == {"status": "ok"}


def test_filtro_magnitud(monkeypatch):
    monkeypatch.setattr(main, "load", lambda p: (SAMPLE, "cache", "x"))
    r = TestClient(main.app).get("/api/earthquakes?period=day&min_mag=2.5").json()
    assert r["metadata"]["count"] == 1


def test_periodo_invalido():
    assert TestClient(main.app).get("/api/earthquakes?period=anio").status_code == 422


def test_respaldo_usgs(monkeypatch):
    monkeypatch.setattr(main, "read_blob", lambda p: None)
    monkeypatch.setattr(main, "fetch_usgs", lambda p: SAMPLE)
    assert main.load("day")[1] == "usgs"


def test_sin_datos(monkeypatch):
    def boom(p):
        raise RuntimeError
    monkeypatch.setattr(main, "read_blob", boom)
    monkeypatch.setattr(main, "fetch_usgs", boom)
    r = TestClient(main.app).get("/api/earthquakes?period=week")
    assert r.status_code == 503
