import json, os, sys, time, urllib.request, urllib.error

BASE = os.environ.get("API_URL", "http://localhost:8000/api")
fails = 0
suffix = str(int(time.time()))[-6:]

def call(method, path, body=None, token=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as r:
            status, text, headers = r.status, r.read().decode(), r.headers
    except urllib.error.HTTPError as e:
        status, text, headers = e.code, e.read().decode(), e.headers
    try:
        payload = json.loads(text) if text else None
    except ValueError:
        payload = text
    return status, payload, headers

def check(name, expected, got):
    global fails
    status, payload, _ = got
    ok = status == expected
    if not ok:
        fails += 1
    print(f"{'OK ' if ok else 'FAIL'} {status} (esperado {expected}) {name}" + ("" if ok else f" -> {payload}"))
    return payload

a = {"username": "Ana", "phone_number": "7" + suffix + "1", "email": f"ana{suffix}@t.com", "pass": "secreto123"}
b = {"username": "Beto", "phone_number": "7" + suffix + "2", "email": f"beto{suffix}@t.com", "pass": "secreto456"}

check("register sin campos", 400, call("POST", "/auth/register", {"username": "x"}))
check("register JSON inválido", 400, call("POST", "/auth/register", raw=b"{no json"))
check("register email inválido", 422, call("POST", "/auth/register", {**a, "email": "malo"}))
check("register pass corta", 422, call("POST", "/auth/register", {**a, "pass": "123"}))
r = check("register A", 201, call("POST", "/auth/register", a))
id_a = r["id_usr"]
id_b = check("register B", 201, call("POST", "/auth/register", b))["id_usr"]
check("register duplicado", 409, call("POST", "/auth/register", a))

check("login pass incorrecta", 401, call("POST", "/auth/login", {"phone_number": a["phone_number"], "pass": "incorrecta1"}))
check("login sin campos", 400, call("POST", "/auth/login", {}))
la = check("login A", 200, call("POST", "/auth/login", {"phone_number": a["phone_number"], "pass": a["pass"]}))
lb = check("login B", 200, call("POST", "/auth/login", {"phone_number": b["phone_number"], "pass": b["pass"]}))
ta, tb = la["token"], lb["token"]

check("ruta privada sin token", 401, call("GET", "/usr/profile"))
check("ruta privada token basura", 401, call("GET", "/usr/profile", token="abc.def.ghi"))
check("refresh token usado como access", 401, call("GET", "/usr/profile", token=la["tkRef"]))
check("ruta inexistente", 404, call("GET", "/no-existe", token=ta))
check("método no permitido", 405, call("PATCH", "/usr/profile", token=ta))
_, _, h = call("OPTIONS", "/auth/login")
print("CORS preflight:", h.get("Access-Control-Allow-Origin"))

p = check("perfil propio", 200, call("GET", "/usr/profile", token=ta))
assert p["id_user"] == id_a, p
check("perfil B", 200, call("GET", f"/usr/profile/{id_b}", token=ta))
check("perfil inexistente", 404, call("GET", "/usr/profile/999999", token=ta))
check("update sin campos", 400, call("PUT", "/usr/update", {}, token=ta))
check("update teléfono de otro", 409, call("PUT", "/usr/update", {"phone_number": b["phone_number"]}, token=ta))
up = check("update descripción", 200, call("PUT", "/usr/update", {"profile_description": "Hola!"}, token=ta))
assert up["profile_description"] == "Hola!", up

# refresh con rotación
r1 = check("refresh", 200, call("POST", "/auth/refresh", {"tkRef": la["tkRef"]}))
check("refresh reutilizado (rotado)", 401, call("POST", "/auth/refresh", {"tkRef": la["tkRef"]}))
check("refresh basura", 401, call("POST", "/auth/refresh", {"tkRef": "x"}))
ta = r1["token"]

# contactos
check("contacto no registrado", 422, call("POST", "/contact/create", {"contact_number": "00000000"}, token=ta))
check("contacto a sí mismo", 422, call("POST", "/contact/create", {"contact_number": a["phone_number"]}, token=ta))
c = check("crear contacto", 201, call("POST", "/contact/create", {"contact_number": b["phone_number"], "contact_name": "Beto"}, token=ta))
id_contact = c["id_contact"]
check("contacto duplicado", 409, call("POST", "/contact/create", {"contact_number": b["phone_number"]}, token=ta))
lst = check("listar contactos", 200, call("GET", "/contact/load/10/1", token=ta))
assert len(lst) == 1, lst
lst = check("listar contactos filtro", 200, call("GET", "/contact/load/10/1?contact_name=zzz", token=ta))
assert lst == [], lst
check("listar lim inválido", 400, call("GET", "/contact/load/0/1", token=ta))
check("update contacto ajeno", 404, call("PUT", "/contact/update", {"id_contact": id_contact, "contact_name": "X"}, token=tb))
check("update contacto id inválido", 400, call("PUT", "/contact/update", {"id_contact": "abc", "contact_name": "X"}, token=ta))
check("update contacto", 204, call("PUT", "/contact/update", {"id_contact": id_contact, "contact_name": "Beto 2"}, token=ta))

# chats
check("chat con contacto ajeno", 404, call("POST", "/chat/create", {"id_contact": id_contact}, token=tb))
ch = check("crear chat", 201, call("POST", "/chat/create", {"id_contact": id_contact}, token=ta))
id_chat = ch["id_chat"]
check("chat duplicado", 409, call("POST", "/chat/create", {"id_contact": id_contact}, token=ta))
check("listar chats", 200, call("GET", "/chat/load", token=ta))

# mensajes
check("enviar a chat ajeno", 404, call("POST", "/message/send", {"id_chat": id_chat, "text_content": "hola"}, token=tb))
check("enviar texto largo", 422, call("POST", "/message/send", {"id_chat": id_chat, "text_content": "x" * 300}, token=ta))
check("enviar mensaje", 201, call("POST", "/message/send", {"id_chat": id_chat, "text_content": "hola Beto"}, token=ta))
msgs = check("cargar mensajes", 200, call("GET", f"/message/load/{id_chat}", token=ta))
assert msgs and msgs[0]["text_message"] == "hola Beto", msgs
id_msg = msgs[0]["id_message"]
check("cargar mensajes chat ajeno", 404, call("GET", f"/message/load/{id_chat}", token=tb))
check("B ve el mensaje en su chat", 200, call("GET", "/chat/load", token=tb))
check("editar mensaje ajeno", 404, call("PUT", "/message/edit", {"id_message": id_msg, "new_text": "hack"}, token=tb))
check("editar mensaje", 204, call("PUT", "/message/edit", {"id_message": id_msg, "new_text": "hola Beto!"}, token=ta))
check("eliminar mensaje ajeno", 404, call("DELETE", f"/message/delete/{id_msg}", token=tb))
check("eliminar mensaje", 204, call("DELETE", f"/message/delete/{id_msg}", token=ta))
check("eliminar mensaje otra vez", 404, call("DELETE", f"/message/delete/{id_msg}", token=ta))

check("eliminar contacto", 204, call("DELETE", f"/contact/delete/{id_contact}", token=ta))
check("eliminar contacto otra vez", 404, call("DELETE", f"/contact/delete/{id_contact}", token=ta))

# logout y desactivación de cuenta
check("logout", 204, call("POST", "/auth/logout", token=ta))
check("refresh tras logout", 401, call("POST", "/auth/refresh", {"tkRef": r1["tkRef"]}))
check("eliminar cuenta pass incorrecta", 403, call("DELETE", "/usr/delete", {"pass": "incorrecta1"}, token=tb))
check("eliminar cuenta", 204, call("DELETE", "/usr/delete", {"pass": b["pass"]}, token=tb))
check("login cuenta eliminada", 401, call("POST", "/auth/login", {"phone_number": b["phone_number"], "pass": b["pass"]}))
check("reactivar pass incorrecta", 401, call("POST", "/auth/reactivate", {"phone_number": b["phone_number"], "pass": "incorrecta1"}))
check("reactivar", 204, call("POST", "/auth/reactivate", {"phone_number": b["phone_number"], "pass": b["pass"]}))
check("login tras reactivar", 200, call("POST", "/auth/login", {"phone_number": b["phone_number"], "pass": b["pass"]}))

print("\nFALLOS:", fails)
sys.exit(1 if fails else 0)
