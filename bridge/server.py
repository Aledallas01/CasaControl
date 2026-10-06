"""Authenticated LAN bridge. Device hosts come only from server configuration."""
import asyncio
import os
import secrets
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from kasa import Credentials, Device, DeviceConfig
from pydantic import BaseModel, ConfigDict, StrictBool

hosts = [host.strip() for host in os.getenv("TAPO_HOSTS", "").split(",") if host.strip()]
bridge_token = os.getenv("BRIDGE_TOKEN", "")
credentials = Credentials(os.getenv("TAPO_USERNAME", ""), os.getenv("TAPO_PASSWORD", ""))
devices = {}
lock = asyncio.Lock()


@asynccontextmanager
async def lifespan(app):
    if len(bridge_token) < 32 or not hosts or not credentials.username or not credentials.password:
        raise RuntimeError("Configure BRIDGE_TOKEN (32+ characters), TAPO_HOSTS, TAPO_USERNAME and TAPO_PASSWORD")
    try:
        yield
    finally:
        for device in devices.values():
            await device.disconnect()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
bearer = HTTPBearer(auto_error=False)


def authorize(auth: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if not bridge_token or auth is None or not secrets.compare_digest(auth.credentials, bridge_token):
        raise HTTPException(401, "Unauthorized")


async def connect(host):
    if host not in devices:
        devices[host] = await Device.connect(config=DeviceConfig(host=host, credentials=credentials))
    return devices[host]


async def discard(host):
    device = devices.pop(host, None)
    if device:
        try:
            await device.disconnect()
        except Exception:
            pass


@app.get("/devices", dependencies=[Depends(authorize)])
async def list_devices():
    result = []
    async with lock:
        for index, host in enumerate(hosts):
            try:
                async with asyncio.timeout(8):
                    device = await connect(host)
                    await device.update()
                    # Only expose devices that advertise controllable power.
                    if "state" not in device.features:
                        continue
                    brightness = device.features.get("brightness")
                    result.append({"id": str(index), "name": device.alias or device.model,
                                   "on": device.is_on, "available": True,
                                   "brightness": brightness.value if brightness else None})
            except Exception:
                await discard(host)
                result.append({"id": str(index), "name": f"Tapo {index + 1}",
                               "on": False, "available": False, "brightness": None})
    return result


class Power(BaseModel):
    model_config = ConfigDict(extra="forbid")
    on: StrictBool


@app.post("/devices/{device_id}/power", dependencies=[Depends(authorize)])
async def power(device_id: int, command: Power):
    if device_id < 0 or device_id >= len(hosts):
        raise HTTPException(404, "Unknown device")
    host = hosts[device_id]
    async with lock:
        try:
            async with asyncio.timeout(8):
                device = await connect(host)
                await device.update()
                if "state" not in device.features:
                    raise HTTPException(422, "Power control unsupported")
                if command.on:
                    await device.turn_on()
                else:
                    await device.turn_off()
                await device.update()
                return {"on": device.is_on}
        except HTTPException:
            raise
        except Exception:
            await discard(host)
            raise HTTPException(502, "Device unreachable or credentials rejected") from None
