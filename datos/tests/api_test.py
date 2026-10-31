#!/usr/bin/env python3
"""Pruebas de la API REST v1 de CR_Chat (contra un entorno desechable).

Uso:  API_URL=http://127.0.0.1:18080 python3 datos/tests/api_test.py
Requiere el seed de demo (Postgres/seed/demo.sql) y MinIO. Solo biblioteca estándar.
Cubre: validación, robo de cuenta (teléfono con forma de email), login por teléfono o email,
IDOR (usuario B/C contra recursos de A -> 404), refresh con rotación y reutilización, logout que
invalida el access al momento, rate limiting (429 + Retry-After), adjuntos con URL prefirmada, etc.
"""
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.environ.get("API_URL", "http://127.0.0.1:18080").rstrip("/")
BASE = ROOT + "/api/v1"
fails = 0
total = 0
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)


def call(method, path, body=None, token=None, raw=None, headers=None, base=BASE):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    url = path if path.startswith("http") else base + path
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", UA)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with opener.open(req, timeout=15) as r:
            status, text, hdrs = r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        status, text, hdrs = e.code, e.read(), e.headers
    try:
        payload = json.loads(text) if text else None
    except ValueError:
        payload = text
    return status, payload, hdrs


def check(name, expected, got, cond=None):
    """expected: int o tupla de estados válidos; cond: función(payload, headers) -> bool."""
    global fails, total
    total += 1
    status, payload, hdrs = got
    exp = expected if isinstance(expected, tuple) else (expected,)
    ok = status in exp
    extra = ""
    if ok and cond is not None:
        try:
            ok = bool(cond(payload, hdrs))
        except Exception as e:  # noqa: BLE001
            ok, extra = False, f" (cond: {e!r})"
        if not ok and not extra:
            extra = " (condición no cumplida)"
    if not ok:
        fails += 1
    print(f"{'OK ' if ok else 'FAIL'} {status} (esperado {'/'.join(map(str, exp))}) {name}"
          + ("" if ok else f"{extra} -> {str(payload)[:400]}"))
    return payload


def is_problem(p, status, slug=None):
    return (isinstance(p, dict) and p.get("status") == status and "title" in p and "detail" in p
            and p.get("type", "").startswith("https://cr-chat.example/problemas/")
            and (slug is None or p["type"].endswith("/" + slug)))


def phone():
    return "+5068" + "".join(random.choice("0123456789") for _ in range(7))


def login(identifier, password, device=None, headers=None):
    body = {"identifier": identifier, "password": password}
    if device:
        body["device_name"] = device
    return call("POST", "/auth/login", body, headers=headers)


suffix = uuid.uuid4().hex[:8]
A = {"email": f"ana.{suffix}@prueba.crchat.local", "phone": phone(), "display_name": "Ana Prueba", "password": "correcto-caballo-bateria-A"}
B = {"email": f"beto.{suffix}@prueba.crchat.local", "phone": phone(), "display_name": "Beto Prueba", "password": "correcto-caballo-bateria-B"}
C = {"email": f"carla.{suffix}@prueba.crchat.local", "phone": phone(), "display_name": "Carla Prueba", "password": "correcto-caballo-bateria-C"}

print("== Plataforma")
check("health", 200, call("GET", "/health"), lambda p, h: p == {"status": "ok"} and h.get("X-Request-Id"))
check("ready (PG rw/ro, Redis, MinIO)", 200, call("GET", "/ready"), lambda p, h: p["status"] == "ok" and set(p["checks"]) == {"db_write", "db_read", "redis", "storage"})
check("encabezados de seguridad", 200, call("GET", "/health"),
      lambda p, h: h.get("X-Content-Type-Options") == "nosniff" and h.get("Referrer-Policy") == "no-referrer" and h.get("Cache-Control") == "no-store")
rid = str(uuid.uuid4())
check("X-Request-Id del proxy se respeta", 200, call("GET", "/health", headers={"X-Request-Id": rid}), lambda p, h: h.get("X-Request-Id") == rid)
check("ruta antigua /api/* -> 410", 410, call("POST", "/api/auth/login", {}, base=ROOT), lambda p, h: is_problem(p, 410, "ruta-retirada"))
check("ruta inexistente -> 404 RFC 9457", 404, call("GET", "/no-existe"), lambda p, h: is_problem(p, 404) and h.get("Content-Type", "").startswith("application/problem+json") and p["instance"] == "/api/v1/no-existe")
check("método no permitido -> 405 con Allow", 405, call("PUT", "/health"), lambda p, h: is_problem(p, 405) and "GET" in h.get("Allow", ""))
check("Swagger UI en /docs", 200, call("GET", "/docs", base=ROOT), lambda p, h: b"swagger-ui" in p and "script-src 'self'" in h.get("Content-Security-Policy", ""))
check("openapi.yaml en /docs/openapi.yaml", 200, call("GET", "/docs/openapi.yaml", base=ROOT), lambda p, h: p.startswith(b"openapi: 3.1"))
check("asset de Swagger UI local (sin CDN)", 200, call("GET", "/docs/swagger-ui-bundle.js", base=ROOT))

print("== CORS")
pre = {"Origin": "http://localhost:5173", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization,content-type"}
check("preflight origen permitido", 204, call("OPTIONS", "/auth/login", headers=pre),
      lambda p, h: h.get("Access-Control-Allow-Origin") == "http://localhost:5173" and "Origin" in h.get("Vary", "") and h.get("Access-Control-Max-Age") == "600")
check("preflight origen no permitido sin ACAO", 204, call("OPTIONS", "/auth/login", headers={**pre, "Origin": "https://malo.example"}),
      lambda p, h: h.get("Access-Control-Allow-Origin") is None and "Origin" in h.get("Vary", ""))
check("respuesta normal expone encabezados", 200, call("GET", "/health", headers={"Origin": "http://localhost:4200"}),
      lambda p, h: h.get("Access-Control-Allow-Origin") == "http://localhost:4200" and "RateLimit" in h.get("Access-Control-Expose-Headers", ""))

print("== Registro")
check("JSON inválido -> 400", 400, call("POST", "/auth/register", raw=b"{no json"), lambda p, h: is_problem(p, 400))
check("campo desconocido -> 400", 400, call("POST", "/auth/register", {**A, "is_admin": True}), lambda p, h: is_problem(p, 400))
check("faltan campos -> 422 con errors[]", 422, call("POST", "/auth/register", {"email": A["email"]}),
      lambda p, h: is_problem(p, 422, "validacion") and {e["field"] for e in p["errors"]} == {"phone", "display_name", "password"})
check("email inválido -> 422", 422, call("POST", "/auth/register", {**A, "email": "malo"}))
check("ROBO DE CUENTA: teléfono con forma de email -> 422", 422, call("POST", "/auth/register", {**A, "phone": "victima@example.com"}),
      lambda p, h: p["errors"][0]["field"] == "phone")
check("teléfono no E.164 -> 422", 422, call("POST", "/auth/register", {**A, "phone": "88880001"}))
check("contraseña corta -> 422", 422, call("POST", "/auth/register", {**A, "password": "123"}))
check("contraseña común -> 422", 422, call("POST", "/auth/register", {**A, "password": "password123"}))
me_a = check("registro A", 201, call("POST", "/auth/register", A),
             lambda p, h: p["email"] == A["email"] and p["phone"] == A["phone"] and h.get("Location") == "/api/v1/me" and "pass" not in json.dumps(p))
check("registro B", 201, call("POST", "/auth/register", B))
check("registro C", 201, call("POST", "/auth/register", C))
dup1 = check("email duplicado -> 409 genérico", 409, call("POST", "/auth/register", {**A, "phone": phone()}), lambda p, h: is_problem(p, 409, "registro-no-disponible"))
dup2 = check("teléfono duplicado -> mismo 409", 409, call("POST", "/auth/register", {**A, "email": f"otro.{suffix}@x.crchat.local"}))
check("409 no revela qué campo colisiona", 200, (200, None, None), lambda p, h: dup1 and dup2 and dup1["detail"] == dup2["detail"])
check("email con mayúsculas es el mismo (citext) -> 409", 409, call("POST", "/auth/register", {**A, "email": A["email"].upper(), "phone": phone()}))

print("== Login (teléfono o email)")
la = check("login A por email", 200, login(A["email"], A["password"], "Pruebas A"),
           lambda p, h: p["token_type"] == "Bearer" and p["expires_in"] == 900 and p["user"]["id"] == me_a["id"] and len(p["refresh_token"]) >= 32 and h.get("Cache-Control") == "no-store")
lb = check("login B por teléfono", 200, login(B["phone"], B["password"]))
lc = check("login C", 200, login(C["email"].upper(), C["password"]))
check("login demo del seed (Ana por teléfono)", 200, login("+50670000001", "Demo-Ana-2026!"))
ta, tb, tc = la["access_token"], lb["access_token"], lc["access_token"]
id_a, id_b, id_c = la["user"]["id"], lb["user"]["id"], lc["user"]["id"]
bad1 = check("contraseña incorrecta -> 401", 401, login(A["email"], "incorrecta-1234"), lambda p, h: is_problem(p, 401))
bad2 = check("usuario inexistente -> mismo 401", 401, login(f"nadie.{suffix}@x.crchat.local", "incorrecta-1234"))
check("401 idénticos (anti-enumeración)", 200, (200, None, None), lambda p, h: bad1["detail"] == bad2["detail"])
check("identificador que no es email ni E.164 -> 422", 422, login("ana", "x"), lambda p, h: p["errors"][0]["field"] == "identifier")
check("login sin campos -> 422", 422, call("POST", "/auth/login", {}))
check("JWT sin teléfono ni email", 200, (200, la, None),
      lambda p, h: set(json.loads(__import__("base64").urlsafe_b64decode(p["access_token"].split(".")[1] + "==")).keys()) == {"iss", "aud", "sub", "sid", "jti", "iat", "exp", "typ"})

print("== Autenticación")
check("sin token -> 401 + WWW-Authenticate", 401, call("GET", "/me"), lambda p, h: is_problem(p, 401) and h.get("WWW-Authenticate", "").startswith("Bearer"))
check("token basura -> 401", 401, call("GET", "/me", token="abc.def.ghi"))
check("refresh usado como access -> 401", 401, call("GET", "/me", token=la["refresh_token"]))

print("== Perfil")
check("GET /me", 200, call("GET", "/me", token=ta), lambda p, h: p["id"] == id_a and p["avatar"] is None)
check("PATCH /me", 200, call("PATCH", "/me", {"display_name": "Ana R.", "about": "Disponible"}, token=ta), lambda p, h: p["display_name"] == "Ana R." and p["about"] == "Disponible")
check("PATCH /me about null quita", 200, call("PATCH", "/me", {"about": None}, token=ta), lambda p, h: p["about"] is None)
check("PATCH /me no permite cambiar teléfono", 400, call("PATCH", "/me", {"phone": phone()}, token=ta))
check("PATCH /me vacío -> 400", 400, call("PATCH", "/me", {}, token=ta))
check("PATCH /me nombre con control -> 422", 422, call("PATCH", "/me", {"display_name": "a\u0000b"}, token=ta))

print("== Contactos")
ca = check("A agrega a B", 201, call("POST", "/contacts", {"phone": B["phone"], "alias": "Beto"}, token=ta),
           lambda p, h: p["user"]["id"] == id_b and p["alias"] == "Beto" and h.get("Location") == f"/api/v1/contacts/{p['id']}")
check("agregar de nuevo es idempotente (200)", 200, call("POST", "/contacts", {"phone": B["phone"]}, token=ta), lambda p, h: p["id"] == ca["id"])
nf1 = check("teléfono no registrado -> 404", 404, call("POST", "/contacts", {"phone": phone()}, token=ta))
check("a uno mismo -> mismo 404", 404, call("POST", "/contacts", {"phone": A["phone"]}, token=ta), lambda p, h: p["detail"] == nf1["detail"])
check("contacto con teléfono inválido -> 422", 422, call("POST", "/contacts", {"phone": "beto@x.com"}, token=ta))
check("phone y user_id a la vez -> 422", 422, call("POST", "/contacts", {"phone": B["phone"], "user_id": id_b}, token=ta))
check("listar contactos", 200, call("GET", "/contacts", token=ta), lambda p, h: [c["id"] for c in p["items"]] == [ca["id"]] and p["next_cursor"] is None)
check("buscar por alias sin acentos", 200, call("GET", "/contacts?q=BETO", token=ta), lambda p, h: len(p["items"]) == 1)
check("buscar por prefijo de teléfono", 200, call("GET", "/contacts?q=" + B["phone"][1:8], token=ta), lambda p, h: len(p["items"]) == 1)
check("limit fuera de rango -> 400", 400, call("GET", "/contacts?limit=500", token=ta))
check("cursor inválido -> 400", 400, call("GET", "/contacts?cursor=%%%", token=ta))
check("GET contacto", 200, call("GET", f"/contacts/{ca['id']}", token=ta))
check("PATCH alias", 200, call("PATCH", f"/contacts/{ca['id']}", {"alias": "Betito"}, token=ta), lambda p, h: p["alias"] == "Betito")
check("PATCH alias inválido -> 422", 422, call("PATCH", f"/contacts/{ca['id']}", {"alias": "x" * 51}, token=ta))
check("IDOR: B lee contacto de A -> 404", 404, call("GET", f"/contacts/{ca['id']}", token=tb), lambda p, h: is_problem(p, 404))
check("IDOR: B edita contacto de A -> 404", 404, call("PATCH", f"/contacts/{ca['id']}", {"alias": "hack"}, token=tb))
check("IDOR: B borra contacto de A -> 404", 404, call("DELETE", f"/contacts/{ca['id']}", token=tb))
check("id mal formado -> 404", 404, call("GET", "/contacts/123", token=ta))

print("== Perfil público")
check("A ve a B (contacto: con teléfono)", 200, call("GET", f"/users/{id_b}", token=ta), lambda p, h: p["phone"] == B["phone"] and "email" not in p)
check("B ve a A (relación inversa: sin teléfono)", 200, call("GET", f"/users/{id_a}", token=tb), lambda p, h: "phone" not in p and "email" not in p)
check("IDOR: C sin relación -> 404", 404, call("GET", f"/users/{id_a}", token=tc))
check("usuario inexistente -> 404", 404, call("GET", f"/users/{uuid.uuid4()}", token=ta))

print("== Conversaciones")
cv = check("A crea conversación con B", 201, call("POST", "/conversations", {"contact_id": ca["id"]}, token=ta),
           lambda p, h: p["peer"]["id"] == id_b and p["is_contact"] and p["contact_alias"] == "Betito" and p["unread_count"] == 0 and p["last_message"] is None)
conv = cv["id"]
check("crear de nuevo es idempotente (200)", 200, call("POST", "/conversations", {"contact_id": ca["id"]}, token=ta), lambda p, h: p["id"] == conv)
check("B ve la conversación como solicitud (is_contact=false)", 200, call("GET", f"/conversations/{conv}", token=tb), lambda p, h: p["is_contact"] is False and p["contact_alias"] is None)
check("IDOR: C lee conversación ajena -> 404", 404, call("GET", f"/conversations/{conv}", token=tc))
check("IDOR: C crea conversación con contacto de A -> 404", 404, call("POST", "/conversations", {"contact_id": ca["id"]}, token=tc))
check("contact_id no uuid -> 422", 422, call("POST", "/conversations", {"contact_id": "1"}, token=ta))

print("== Mensajes")
cid = str(uuid.uuid4())
m1 = check("A envía mensaje", 201, call("POST", f"/conversations/{conv}/messages", {"client_id": cid, "text": "Hola, ¿cómo estás?"}, token=ta),
           lambda p, h: p["text"] == "Hola, ¿cómo estás?" and p["client_id"] == cid and p["status"] == "sent" and p["sender_id"] == id_a and p["cursor"])
check("reintento con el mismo client_id -> 200 mismo mensaje", 200, call("POST", f"/conversations/{conv}/messages", {"client_id": cid, "text": "Hola, ¿cómo estás?"}, token=ta), lambda p, h: p["id"] == m1["id"])
idem = str(uuid.uuid4())
m2 = check("Idempotency-Key", 201, call("POST", f"/conversations/{conv}/messages", {"text": "segundo"}, token=ta, headers={"Idempotency-Key": idem}), lambda p, h: p["client_id"] == idem)
check("Idempotency-Key repetida -> 200", 200, call("POST", f"/conversations/{conv}/messages", {"text": "segundo"}, token=ta, headers={"Idempotency-Key": idem}), lambda p, h: p["id"] == m2["id"])
check("client_id reutilizado en otra conversación -> 409", (409, 404), call("POST", f"/conversations/{uuid.uuid4()}/messages", {"client_id": cid, "text": "x"}, token=ta))
check("sin text ni media_id -> 422", 422, call("POST", f"/conversations/{conv}/messages", {}, token=ta), lambda p, h: p["errors"][0]["field"] == "text")
check("texto > 4000 -> 422", 422, call("POST", f"/conversations/{conv}/messages", {"text": "x" * 4001}, token=ta))
check("IDOR: C envía a conversación ajena -> 404", 404, call("POST", f"/conversations/{conv}/messages", {"text": "intruso"}, token=tc))
check("IDOR: C lista mensajes ajenos -> 404", 404, call("GET", f"/conversations/{conv}/messages", token=tc))
lst = check("B lista mensajes (descifrados, ascendente)", 200, call("GET", f"/conversations/{conv}/messages", token=tb),
            lambda p, h: [m["id"] for m in p["items"]] == [m1["id"], m2["id"]] and p["items"][0]["text"] == "Hola, ¿cómo estás?"
            and p["items"][0]["client_id"] is None and "status" not in p["items"][0] and p["next_cursor"] is None)
check("listar marca entregado (A ve status delivered)", 200, call("GET", f"/conversations/{conv}/messages", token=ta), lambda p, h: all(m["status"] == "delivered" for m in p["items"]))
pg = check("paginación limit=1 (más recientes)", 200, call("GET", f"/conversations/{conv}/messages?limit=1", token=ta), lambda p, h: p["items"][0]["id"] == m2["id"] and p["next_cursor"])
check("before=cursor", 200, call("GET", f"/conversations/{conv}/messages?limit=1&before={pg['next_cursor']}", token=ta), lambda p, h: p["items"][0]["id"] == m1["id"])
check("after=cursor (resincronización)", 200, call("GET", f"/conversations/{conv}/messages?after={m1['cursor']}", token=ta), lambda p, h: [m["id"] for m in p["items"]] == [m2["id"]])
check("before y after a la vez -> 400", 400, call("GET", f"/conversations/{conv}/messages?after={m1['cursor']}&before={m1['cursor']}", token=ta))
check("cursor inválido -> 400", 400, call("GET", f"/conversations/{conv}/messages?before=xyz", token=ta))
check("unread_count de B = 2", 200, call("GET", "/conversations", token=tb), lambda p, h: p["items"][0]["id"] == conv and p["items"][0]["unread_count"] == 2 and p["items"][0]["last_message"]["id"] == m2["id"])
check("receipts status inválido -> 422", 422, call("POST", f"/conversations/{conv}/receipts", {"status": "read", "up_to_message_id": m1["id"]}, token=tb))
check("B marca visto hasta m1", 200, call("POST", f"/conversations/{conv}/receipts", {"status": "seen", "up_to_message_id": m1["id"]}, token=tb),
      lambda p, h: p["updated_count"] == 1 and p["unread_count"] == 1)
check("IDOR: C marca recibos ajenos -> 404", 404, call("POST", f"/conversations/{conv}/receipts", {"status": "seen", "up_to_message_id": m1["id"]}, token=tc))
mb = check("B responde", 201, call("POST", f"/conversations/{conv}/messages", {"text": "¡Bien!"}, token=tb))
check("responder marca visto lo anterior (m2 seen para A)", 200, call("GET", f"/conversations/{conv}/messages", token=ta),
      lambda p, h: {m["id"]: m.get("status") for m in p["items"]}[m2["id"]] == "seen")
check("unread_count de B = 0", 200, call("GET", f"/conversations/{conv}", token=tb), lambda p, h: p["unread_count"] == 0)
check("B edita mensaje de A -> 403 no-autor", 403, call("PATCH", f"/messages/{m1['id']}", {"text": "hack"}, token=tb), lambda p, h: is_problem(p, 403, "no-autor"))
check("IDOR: C edita mensaje de A -> 404", 404, call("PATCH", f"/messages/{m1['id']}", {"text": "hack"}, token=tc))
check("A edita su mensaje", 200, call("PATCH", f"/messages/{m1['id']}", {"text": "Hola (editado)"}, token=ta), lambda p, h: p["text"] == "Hola (editado)" and p["edited_at"])
check("edición vacía -> 422", 422, call("PATCH", f"/messages/{m1['id']}", {"text": ""}, token=ta))
check("B borra mensaje de A -> 403 no-autor", 403, call("DELETE", f"/messages/{m1['id']}", token=tb))
check("IDOR: C borra mensaje de A -> 404", 404, call("DELETE", f"/messages/{m1['id']}", token=tc))
check("A borra su mensaje", 204, call("DELETE", f"/messages/{m1['id']}", token=ta))
check("borrar de nuevo es idempotente", 204, call("DELETE", f"/messages/{m1['id']}", token=ta))
check("lápida en el listado", 200, call("GET", f"/conversations/{conv}/messages", token=tb),
      lambda p, h: p["items"][0]["id"] == m1["id"] and p["items"][0]["deleted_at"] and p["items"][0]["text"] is None)
check("editar lápida -> 404", 404, call("PATCH", f"/messages/{m1['id']}", {"text": "revivir"}, token=ta))

print("== Bloqueos")
check("C no puede bloquear sin relación -> 404", 404, call("PUT", f"/blocks/{id_a}", token=tc))
check("B bloquea a A", 204, call("PUT", f"/blocks/{id_a}", token=tb))
check("bloquear de nuevo (idempotente)", 204, call("PUT", f"/blocks/{id_a}", token=tb))
check("A no puede enviar -> 403 bloqueado", 403, call("POST", f"/conversations/{conv}/messages", {"text": "¿hola?"}, token=ta), lambda p, h: is_problem(p, 403, "bloqueado"))
check("A no ve el perfil de B -> 404", 404, call("GET", f"/users/{id_b}", token=ta))
check("listar bloqueos de B", 200, call("GET", "/blocks", token=tb), lambda p, h: p["items"][0]["user"]["id"] == id_a)
check("B desbloquea a A", 204, call("DELETE", f"/blocks/{id_a}", token=tb))
check("desbloquear de nuevo (idempotente)", 204, call("DELETE", f"/blocks/{id_a}", token=tb))
check("A vuelve a enviar", 201, call("POST", f"/conversations/{conv}/messages", {"text": "ya"}, token=ta))
check("bloquearse a uno mismo -> 422", 422, call("PUT", f"/blocks/{id_a}", token=ta))

print("== Adjuntos y avatares (MinIO)")
png = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000" "1f15c4890000000d49444154789c6360000002000154a24f9a0000000049454e44ae426082")
up = check("solicitar subida", 201, call("POST", "/uploads", {"purpose": "message", "content_type": "image/png", "size_bytes": len(png)}, token=ta),
           lambda p, h: p["method"] == "PUT" and p["headers"]["Content-Type"] == "image/png" and "X-Amz-Signature" in p["upload_url"] and "clave_objeto" not in json.dumps(p))
check("subida con tipo no permitido -> 422", 422, call("POST", "/uploads", {"purpose": "message", "content_type": "text/html", "size_bytes": 10}, token=ta))
check("avatar > 2 MiB -> 422", 422, call("POST", "/uploads", {"purpose": "avatar", "content_type": "image/png", "size_bytes": 3 * 1024 * 1024}, token=ta))
check("mensaje con media no subida -> 422", 422, call("POST", f"/conversations/{conv}/messages", {"media_id": up["media_id"]}, token=ta), lambda p, h: p["errors"][0]["field"] == "media_id")
check("PUT con Content-Type distinto al firmado -> 403", 403, call("PUT", up["upload_url"], raw=png, headers={"Content-Type": "image/jpeg"}))
check("PUT a MinIO con la URL prefirmada", 200, call("PUT", up["upload_url"], raw=png, headers=up["headers"]))
check("IDOR: B usa la media de A -> 422", 422, call("POST", f"/conversations/{conv}/messages", {"media_id": up["media_id"]}, token=tb))
mm = check("mensaje con adjunto", 201, call("POST", f"/conversations/{conv}/messages", {"media_id": up["media_id"], "text": "foto"}, token=ta),
           lambda p, h: p["media"]["id"] == up["media_id"] and p["media"]["size_bytes"] == len(png) and p["media"]["url"].startswith("http"))
check("descargar adjunto con URL GET prefirmada", 200, call("GET", mm["media"]["url"]), lambda p, h: p == png)
check("reusar la misma media en otro mensaje -> 422", 422, call("POST", f"/conversations/{conv}/messages", {"media_id": up["media_id"]}, token=ta))
av = call("POST", "/uploads", {"purpose": "avatar", "content_type": "image/png", "size_bytes": len(png)}, token=ta)[1]
call("PUT", av["upload_url"], raw=png, headers=av["headers"])
check("avatar de mensaje no sirve como avatar -> 422", 422, call("PATCH", "/me", {"avatar_media_id": up["media_id"]}, token=ta))
check("PATCH /me con avatar", 200, call("PATCH", "/me", {"avatar_media_id": av["media_id"]}, token=ta), lambda p, h: p["avatar"]["id"] == av["media_id"])
check("B ve el avatar de A en la conversación", 200, call("GET", f"/conversations/{conv}", token=tb), lambda p, h: p["peer"]["avatar"]["id"] == av["media_id"])
check("quitar avatar", 200, call("PATCH", "/me", {"avatar_media_id": None}, token=ta), lambda p, h: p["avatar"] is None)

print("== Contacto desde solicitud de mensaje (user_id)")
check("B agrega a A por user_id (201, o 501 si falta fn_crear_contacto_usuario)", (201, 501), call("POST", "/contacts", {"user_id": id_a}, token=tb))
check("C agrega por user_id sin relación -> 404 (o 501)", (404, 501), call("POST", "/contacts", {"user_id": id_a}, token=tc))

print("== Sesiones")
la2 = check("A inicia segunda sesión", 200, login(A["phone"], A["password"]))
check("device_name derivado del User-Agent", 200, call("GET", "/me/sessions", token=ta),
      lambda p, h: {s["device_name"] for s in p["items"]} >= {"Pruebas A", "Firefox en Linux"} and sum(s["current"] for s in p["items"]) == 1)
check("IDOR: B revoca sesión de A -> 404", 404, call("DELETE", f"/me/sessions/{la2['session_id']}", token=tb))
check("A revoca la segunda sesión", 204, call("DELETE", f"/me/sessions/{la2['session_id']}", token=ta))
check("access de la sesión revocada -> 401 al momento", 401, call("GET", "/me", token=la2["access_token"]))
check("refresh de la sesión revocada -> 401", 401, call("POST", "/auth/refresh", {"refresh_token": la2["refresh_token"]}))
la3 = login(A["email"], A["password"])[1]
check("cerrar las demás sesiones", 204, call("DELETE", "/me/sessions", token=ta))
check("las demás quedan revocadas", 401, call("GET", "/me", token=la3["access_token"]))
check("la actual sigue activa", 200, call("GET", "/me", token=ta))

print("== Refresh (rotación y reutilización)")
r1 = check("refresh rota el par", 200, call("POST", "/auth/refresh", {"refresh_token": lc["refresh_token"]}),
           lambda p, h: p["refresh_token"] != lc["refresh_token"] and p["session_id"] == lc["session_id"])
check("el access nuevo funciona", 200, call("GET", "/me", token=r1["access_token"]))
check("refresh basura -> 401", 401, call("POST", "/auth/refresh", {"refresh_token": "x" * 43}))
check("refresh demasiado corto -> 401", 401, call("POST", "/auth/refresh", {"refresh_token": "corto"}))
check("REUTILIZACIÓN del refresh rotado -> 401", 401, call("POST", "/auth/refresh", {"refresh_token": lc["refresh_token"]}))
check("tras la reutilización la sesión queda revocada (access nuevo -> 401)", 401, call("GET", "/me", token=r1["access_token"]))
check("y el refresh nuevo tampoco sirve", 401, call("POST", "/auth/refresh", {"refresh_token": r1["refresh_token"]}))

print("== Refresh en cookie HttpOnly (A-15)")
ck = check("login en modo cookie", 200, login(C["phone"], C["password"], headers={"X-Refresh-Cookie": "1"}),
           lambda p, h: "refresh_token" not in p and "HttpOnly" in h.get("Set-Cookie", "") and "SameSite=Strict" in h.get("Set-Cookie", "") and "Path=/api/v1/auth" in h.get("Set-Cookie", ""))
cookie = None
st, _, hh = login(C["phone"], C["password"], headers={"X-Refresh-Cookie": "1"})
cookie = hh.get("Set-Cookie").split(";")[0]
check("refresh con la cookie", 200, call("POST", "/auth/refresh", headers={"X-Refresh-Cookie": "1", "Cookie": cookie, "Origin": "http://localhost:5173"}),
      lambda p, h: "refresh_token" not in p and h.get("Set-Cookie", "").startswith("cr_refresh="))
check("refresh con cookie desde otro Origin -> 403", 403, call("POST", "/auth/refresh", headers={"X-Refresh-Cookie": "1", "Cookie": cookie, "Origin": "https://malo.example"}))
check("sin X-Refresh-Cookie la cookie no se usa -> 422", 422, call("POST", "/auth/refresh", {}, headers={"Cookie": cookie}))
tc = login(C["phone"], C["password"])[1]["access_token"]

print("== Logout")
lx = login(B["email"], B["password"])[1]
check("logout", 204, call("POST", "/auth/logout", token=lx["access_token"]))
check("access tras logout -> 401 al momento", 401, call("GET", "/me", token=lx["access_token"]))
check("refresh tras logout -> 401", 401, call("POST", "/auth/refresh", {"refresh_token": lx["refresh_token"]}))
check("la otra sesión de B sigue activa", 200, call("GET", "/me", token=tb))

print("== Cambio de contraseña y teléfono")
lb2 = login(B["email"], B["password"])[1]
check("contraseña actual incorrecta -> 403", 403, call("PUT", "/me/password", {"current_password": "incorrecta", "new_password": "nueva-contrasena-segura-B"}, token=tb),
      lambda p, h: is_problem(p, 403, "contrasena-incorrecta"))
check("nueva contraseña débil -> 422", 422, call("PUT", "/me/password", {"current_password": B["password"], "new_password": "corta"}, token=tb))
check("cambiar contraseña", 204, call("PUT", "/me/password", {"current_password": B["password"], "new_password": "nueva-contrasena-segura-B"}, token=tb))
check("las demás sesiones quedan revocadas", 401, call("GET", "/me", token=lb2["access_token"]))
check("la actual se conserva", 200, call("GET", "/me", token=tb))
check("login con la contraseña vieja -> 401", 401, login(B["email"], B["password"]))
B["password"] = "nueva-contrasena-segura-B"
check("login con la nueva", 200, login(B["email"], B["password"]))
# (otro usuario: la política `sensitive` es de 5 por 15 min por usuario)
check("cambiar a un teléfono en uso -> 409 genérico", 409, call("PUT", "/me/phone", {"current_password": A["password"], "phone": B["phone"]}, token=ta), lambda p, h: is_problem(p, 409))
check("teléfono con forma de email -> 422", 422, call("PUT", "/me/phone", {"current_password": A["password"], "phone": B["email"]}, token=ta))
newp = phone()
check("cambiar teléfono", 200, call("PUT", "/me/phone", {"current_password": A["password"], "phone": newp}, token=ta), lambda p, h: p["phone"] == newp)
check("login con el teléfono nuevo", 200, login(newp, A["password"]))
for _ in range(2):  # B ya hizo 3 operaciones sensibles; con estas llega a 5
    call("PUT", "/me/password", {"current_password": "incorrecta", "new_password": "nueva-contrasena-segura-X"}, token=tb)
check("sensitive: 6.ª operación sensible en 15 min -> 429", 429, call("PUT", "/me/password", {"current_password": "x", "new_password": "y"}, token=tb),
      lambda p, h: h.get("RateLimit-Policy") == '"sensitive";q=5;w=900' and int(h["Retry-After"]) > 0)

print("== Baja y reactivación")
check("baja con contraseña incorrecta -> 403", 403, call("DELETE", "/me", {"password": "incorrecta"}, token=tc))
check("baja de C", 204, call("DELETE", "/me", {"password": C["password"]}, token=tc))
check("access de C tras la baja -> 401", 401, call("GET", "/me", token=tc))
check("login de cuenta desactivada -> 401", 401, login(C["email"], C["password"]))
check("reactivar con contraseña incorrecta -> 401", 401, call("POST", "/auth/reactivate", {"identifier": C["email"], "password": "incorrecta-123"}))
check("reactivar cuenta activa -> 401", 401, call("POST", "/auth/reactivate", {"identifier": A["email"], "password": A["password"]}))
check("reactivar", 204, call("POST", "/auth/reactivate", {"identifier": C["email"], "password": C["password"]}))
check("login tras reactivar", 200, login(C["email"], C["password"]))

print("== Rate limiting")
victima = f"rl.{suffix}@x.crchat.local"
for i in range(5):
    call("POST", "/auth/login", {"identifier": victima, "password": "incorrecta-123"})
check("6.º login fallido en 1 min -> 429 + Retry-After", 429, call("POST", "/auth/login", {"identifier": victima, "password": "incorrecta-123"}),
      lambda p, h: is_problem(p, 429, "demasiadas-peticiones") and int(h.get("Retry-After", "0")) >= 1 and h.get("RateLimit-Policy", "").startswith('"login";q=5;w=60'))
check("otro identificador no se ve afectado", 401, call("POST", "/auth/login", {"identifier": f"otro.{suffix}@x.crchat.local", "password": "incorrecta-123"}),
      lambda p, h: h.get("RateLimit", "").startswith('"login'))
check("respuestas autenticadas traen RateLimit", 200, call("GET", "/me", token=ta),
      lambda p, h: h.get("RateLimit-Policy") == '"default-auth";q=300;w=60' and h.get("RateLimit", "").startswith('"default-auth";r='))

print(f"\nTOTAL: {total}  FALLOS: {fails}")
sys.exit(1 if fails else 0)
