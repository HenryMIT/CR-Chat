#!/usr/bin/env python3
"""Pruebas del servidor WebSocket (Workerman) de CR_Chat, según docs/contratos/ws-eventos.md.

Uso:  API_URL=http://127.0.0.1:18080 WS_URL=ws://127.0.0.1:18081/ws python3 datos/tests/ws_test.py
Requiere el paquete `websockets` (>= 10). Dos usuarios: A envía por REST y B recibe message.new
en menos de 1 s; typing, seen, presencia, reautenticación, revocación y resincronización.
"""
import asyncio
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
import uuid

import websockets

API = os.environ.get("API_URL", "http://127.0.0.1:18080").rstrip("/") + "/api/v1"
WS = os.environ.get("WS_URL", "ws://127.0.0.1:18081/ws")
ORIGIN = "http://localhost:5173"
fails = 0
total = 0


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            text = r.read()
            return r.status, json.loads(text) if text else None
    except urllib.error.HTTPError as e:
        text = e.read()
        return e.code, json.loads(text) if text else None


def check(name, ok, detail=""):
    global fails, total
    total += 1
    if not ok:
        fails += 1
    print(f"{'OK ' if ok else 'FAIL'} {name}" + ("" if ok else f" -> {detail}"))


def env(type_, data=None):
    return json.dumps({"type": type_, "id": str(uuid.uuid4()), "ts": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), "data": data or {}})


async def connect(**kw):
    return await websockets.connect(WS, origin=ORIGIN, subprotocols=["cr-chat.v1"], open_timeout=5, **kw)


async def auth(ws, token):
    msg_id = str(uuid.uuid4())
    await ws.send(json.dumps({"type": "auth", "id": msg_id, "ts": "", "data": {"access_token": token}}))
    # Puede haber eventos en cola antes de la respuesta: se espera auth.ok o error
    reply, _ = await wait_for(ws, lambda e: e["type"] in ("auth.ok", "error") and e["data"].get("reply_to") in (msg_id, None), 3)
    return reply or {"type": "timeout", "data": {}}, msg_id


async def wait_for(ws, pred, timeout=2.0):
    """Lee eventos hasta que uno cumpla pred; devuelve (evento, segundos) o (None, timeout)."""
    start = time.monotonic()
    while True:
        left = timeout - (time.monotonic() - start)
        if left <= 0:
            return None, timeout
        try:
            ev = json.loads(await asyncio.wait_for(ws.recv(), left))
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            return None, timeout
        if pred(ev):
            return ev, time.monotonic() - start


async def closed_with(ws, timeout=7.0):
    try:
        while True:
            await asyncio.wait_for(ws.recv(), timeout)
    except websockets.ConnectionClosed:
        return ws.close_code, ws.close_reason
    except asyncio.TimeoutError:
        return None, "timeout"


def phone():
    return "+5068" + "".join(random.choice("0123456789") for _ in range(7))


def new_user(name):
    u = {"email": f"{name}.{uuid.uuid4().hex[:8]}@ws.crchat.local", "phone": phone(), "display_name": name, "password": "correcto-caballo-bateria-ws"}
    st, _ = call("POST", "/auth/register", u)
    assert st == 201, st
    st, tok = call("POST", "/auth/login", {"identifier": u["email"], "password": u["password"]})
    assert st == 200, (st, tok)
    u.update(tok=tok["access_token"], refresh=tok["refresh_token"], id=tok["user"]["id"], sid=tok["session_id"])
    return u


def relogin(u):
    st, tok = call("POST", "/auth/login", {"identifier": u["phone"], "password": u["password"]})
    assert st == 200
    return tok


async def main():
    a, b, c = new_user("Ana"), new_user("Beto"), new_user("Carla")
    _, contact = call("POST", "/contacts", {"phone": b["phone"], "alias": "Beto"}, a["tok"])
    _, conv = call("POST", "/conversations", {"contact_id": contact["id"]}, a["tok"])
    conv_id = conv["id"]

    print("== Handshake y autenticación")
    try:
        await websockets.connect(WS, origin="https://malo.example", open_timeout=5)
        check("Origin no permitido -> 403 en el handshake", False, "se conectó")
    except websockets.InvalidStatusCode as e:
        check("Origin no permitido -> 403 en el handshake", e.status_code == 403, e.status_code)

    ws = await connect()
    check("subprotocolo cr-chat.v1 negociado", ws.subprotocol == "cr-chat.v1", ws.subprotocol)
    await ws.send(env("ping"))
    code, _ = await closed_with(ws)
    check("mensaje antes de auth -> cierre 4003", code == 4003, code)

    ws = await connect()
    t0 = time.monotonic()
    code, _ = await closed_with(ws, 8)
    check("sin auth en 5 s -> cierre 4001", code == 4001 and 4.5 <= time.monotonic() - t0 <= 7, (code, time.monotonic() - t0))

    ws = await connect()
    reply, _ = await auth(ws, "abc.def.ghi")
    code, _ = await closed_with(ws)
    check("token inválido -> error invalid_token + 4401", reply["type"] == "error" and reply["data"]["code"] == "invalid_token" and code == 4401, (reply, code))

    print("== Mensajes en tiempo real")
    wa1, wa2, wb = await connect(), await connect(), await connect()
    ra, mid = await auth(wa1, a["tok"])
    check("auth.ok con reply_to, user_id y session_id", ra["type"] == "auth.ok" and ra["data"]["reply_to"] == mid
          and ra["data"]["user_id"] == a["id"] and ra["data"]["session_id"] == a["sid"] and ra["data"]["heartbeat_interval"] == 25, ra)
    await auth(wa2, a["tok"])
    rb, _ = await auth(wb, b["tok"])
    check("B autenticado", rb["type"] == "auth.ok", rb)

    await wb.send(env("ping"))
    pong, _ = await wait_for(wb, lambda e: e["type"] == "pong")
    check("ping -> pong", pong is not None)

    await wb.send(env("presence.query", {"user_ids": [a["id"], c["id"]]}))
    pres, _ = await wait_for(wb, lambda e: e["type"] == "presence" and e["data"]["user_id"] == a["id"])
    check("presence.query: A online (relacionado)", pres is not None and pres["data"]["status"] == "online", pres)
    noc, _ = await wait_for(wb, lambda e: e["type"] == "presence" and e["data"]["user_id"] == c["id"], 0.7)
    check("presence.query: C sin relación no se informa", noc is None, noc)

    client_id = str(uuid.uuid4())
    t_send = time.monotonic()
    st, msg = call("POST", f"/conversations/{conv_id}/messages", {"client_id": client_id, "text": "Hola en tiempo real"}, a["tok"])
    ev_b, dt = await wait_for(wb, lambda e: e["type"] == "message.new")
    lat = time.monotonic() - t_send
    check(f"B recibe message.new en < 1 s ({lat * 1000:.0f} ms)", ev_b is not None and lat < 1.0 and ev_b["data"]["message"]["id"] == msg["id"], ev_b)
    check("B ve el texto descifrado sin client_id", ev_b and ev_b["data"]["message"]["text"] == "Hola en tiempo real" and ev_b["data"]["message"]["client_id"] is None, ev_b)
    ev_a2, _ = await wait_for(wa2, lambda e: e["type"] == "message.new")
    check("la otra conexión de A recibe su mensaje con client_id", ev_a2 is not None and ev_a2["data"]["message"]["client_id"] == client_id, ev_a2)
    deliv, _ = await wait_for(wa1, lambda e: e["type"] == "receipt.delivered")
    check("A recibe receipt.delivered automático", deliv is not None and deliv["data"]["user_id"] == b["id"] and deliv["data"]["up_to_message_id"] == msg["id"], deliv)

    print("== typing y seen")
    await wb.send(env("typing", {"conversation_id": conv_id, "state": "start"}))
    ty, dt = await wait_for(wa1, lambda e: e["type"] == "typing")
    check("A recibe typing start de B", ty is not None and ty["data"] == {"conversation_id": conv_id, "user_id": b["id"], "state": "start"}, ty)
    await wb.send(env("typing", {"conversation_id": conv_id, "state": "stop"}))
    ty, _ = await wait_for(wa1, lambda e: e["type"] == "typing" and e["data"]["state"] == "stop")
    check("A recibe typing stop", ty is not None, ty)

    wc = await connect()
    await auth(wc, c["tok"])
    await wc.send(env("typing", {"conversation_id": conv_id, "state": "start"}))
    err, _ = await wait_for(wc, lambda e: e["type"] == "error")
    check("typing a conversación ajena -> error not_found", err is not None and err["data"]["code"] == "not_found", err)
    await wc.send(env("seen", {"conversation_id": conv_id, "up_to_message_id": msg["id"]}))
    err, _ = await wait_for(wc, lambda e: e["type"] == "error")
    check("seen a conversación ajena -> error not_found", err is not None and err["data"]["code"] == "not_found", err)
    await wc.send(env("no.existe"))
    err, _ = await wait_for(wc, lambda e: e["type"] == "error")
    check("type desconocido -> error unknown_type", err is not None and err["data"]["code"] == "unknown_type", err)
    await wc.close()

    seen_id = str(uuid.uuid4())
    await wb.send(json.dumps({"type": "seen", "id": seen_id, "ts": "", "data": {"conversation_id": conv_id, "up_to_message_id": msg["id"]}}))
    rs, _ = await wait_for(wa1, lambda e: e["type"] == "receipt.seen")
    check("A recibe receipt.seen", rs is not None and rs["data"]["user_id"] == b["id"] and rs["data"]["up_to_message_id"] == msg["id"], rs)
    st, cv = call("GET", f"/conversations/{conv_id}", token=b["tok"])
    check("unread_count de B = 0 por REST", st == 200 and cv["unread_count"] == 0, cv)

    st, _ = call("PUT", f"/blocks/{a['id']}", token=b["tok"])
    await wa1.send(env("typing", {"conversation_id": conv_id, "state": "start"}))
    err, _ = await wait_for(wa1, lambda e: e["type"] == "error")
    check("typing con bloqueo -> error blocked", err is not None and err["data"]["code"] == "blocked", err)
    call("DELETE", f"/blocks/{a['id']}", token=b["tok"])

    print("== Edición, borrado y conversación nueva")
    call("PATCH", f"/messages/{msg['id']}", {"text": "editado"}, a["tok"])
    ed, _ = await wait_for(wb, lambda e: e["type"] == "message.edited")
    check("B recibe message.edited", ed is not None and ed["data"]["message"]["text"] == "editado" and ed["data"]["message"]["edited_at"], ed)
    call("DELETE", f"/messages/{msg['id']}", token=a["tok"])
    de, _ = await wait_for(wb, lambda e: e["type"] == "message.deleted")
    check("B recibe message.deleted", de is not None and de["data"]["message_id"] == msg["id"] and de["data"]["conversation_id"] == conv_id, de)
    _, cc = call("POST", "/contacts", {"phone": c["phone"]}, b["tok"])
    wc = await connect()
    await auth(wc, c["tok"])
    st, conv_bc = call("POST", "/conversations", {"contact_id": cc["id"]}, b["tok"])
    nb, _ = await wait_for(wb, lambda e: e["type"] == "conversation.new")
    nc, _ = await wait_for(wc, lambda e: e["type"] == "conversation.new")
    check("conversation.new para ambos con la vista de cada uno", nb and nc and nb["data"]["conversation"]["peer"]["id"] == c["id"]
          and nc["data"]["conversation"]["peer"]["id"] == b["id"] and nc["data"]["conversation"]["is_contact"] is False, (nb, nc))
    await wc.close()

    print("== Reautenticación")
    st, ref = call("POST", "/auth/refresh", {"refresh_token": a["refresh"]})
    ra2, _ = await auth(wa1, ref["access_token"])
    check("reautenticación sobre la misma conexión -> auth.ok", ra2["type"] == "auth.ok" and ra2["data"]["user_id"] == a["id"], ra2)
    call("POST", f"/conversations/{conv_id}/messages", {"text": "tras reauth"}, b["tok"])
    ev, _ = await wait_for(wa1, lambda e: e["type"] == "message.new")
    check("la conexión sigue recibiendo eventos", ev is not None and ev["data"]["message"]["text"] == "tras reauth", ev)
    rx, _ = await auth(wa2, b["tok"])
    code, _ = await closed_with(wa2)
    check("reautenticar con token de otro usuario -> 4401", rx["type"] == "error" and code == 4401, (rx, code))

    print("== Revocación y resincronización")
    st, _ = call("POST", "/auth/logout", token=ref["access_token"])
    code, reason = await closed_with(wa1, 3)
    check("logout de A cierra su WebSocket con 4401", st == 204 and code == 4401 and reason == "session_revoked", (st, code, reason))
    await asyncio.sleep(0.3)
    a2 = relogin(a)
    wa = await connect()
    await auth(wa, a2["access_token"])
    rev, _ = await wait_for(wb, lambda e: e["type"] == "presence" and e["data"]["user_id"] == a["id"], 3)
    check("B recibe presence de A al reconectar", rev is not None, rev)
    st, page = call("GET", f"/conversations/{conv_id}/messages?limit=1", token=a2["access_token"])
    last_cursor = page["items"][-1]["cursor"]
    await wa.close()
    off, _ = await wait_for(wb, lambda e: e["type"] == "presence" and e["data"]["status"] == "offline", 3)
    check("B recibe presence offline con last_seen_at", off is not None and off["data"]["last_seen_at"], off)
    call("POST", f"/conversations/{conv_id}/messages", {"text": "mientras estabas fuera"}, b["tok"])
    wa = await connect()
    await auth(wa, a2["access_token"])
    st, missed = call("GET", f"/conversations/{conv_id}/messages?after={last_cursor}", token=a2["access_token"])
    check("resincronización con ?after= recupera lo perdido", st == 200 and [m["text"] for m in missed["items"]] == ["mientras estabas fuera"], missed)
    await wa.close()
    await wb.close()

    print("== Límites")
    wl = await connect()
    await auth(wl, c["tok"])
    for _ in range(25):
        await wl.send(env("ping"))
    rl, _ = await wait_for(wl, lambda e: e["type"] == "error" and e["data"]["code"] == "rate_limited", 3)
    check("más de 20 mensajes en 10 s -> error rate_limited", rl is not None and rl["data"]["retry_after"] > 0, rl)
    await wl.send("x" * 20000)
    code, _ = await closed_with(wl, 3)
    check("frame > 16 KiB -> cierre 1009", code == 1009, code)

    print(f"\nTOTAL: {total}  FALLOS: {fails}")
    return fails


if __name__ == "__main__":
    sys.exit(1 if asyncio.run(main()) else 0)
