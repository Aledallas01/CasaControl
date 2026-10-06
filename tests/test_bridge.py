import os
os.environ.update(BRIDGE_TOKEN="a" * 32, TAPO_HOSTS="192.0.2.1", TAPO_USERNAME="test", TAPO_PASSWORD="test")
from unittest.mock import AsyncMock
from fastapi.testclient import TestClient
from bridge import server

headers = {"Authorization": "Bearer " + "a" * 32}


def test_auth_and_unknown_device():
    with TestClient(server.app) as client:
        assert client.get("/devices").status_code == 401
        assert client.post("/devices/-1/power", headers=headers, json={"on": True}).status_code == 404
        assert client.post("/devices/1/power", headers=headers, json={"on": True}).status_code == 404
        assert client.post("/devices/0/power", headers=headers, json={"on": "false"}).status_code == 422


def test_power_and_unavailable(monkeypatch):
    device = AsyncMock()
    device.features = {"state": object()}
    device.alias = "Lampada"
    device.is_on = True
    monkeypatch.setattr(server, "connect", AsyncMock(return_value=device))
    with TestClient(server.app) as client:
        response = client.post("/devices/0/power", headers=headers, json={"on": False})
        assert response.status_code == 200
        device.turn_off.assert_awaited_once()
        device.turn_on.assert_not_awaited()
        assert client.get("/devices", headers=headers).json()[0]["name"] == "Lampada"
        monkeypatch.setattr(server, "connect", AsyncMock(side_effect=RuntimeError("secret")))
        response = client.get("/devices", headers=headers)
        assert response.json()[0]["available"] is False
        response = client.post("/devices/0/power", headers=headers, json={"on": True})
        assert response.status_code == 502
        assert "secret" not in response.text
