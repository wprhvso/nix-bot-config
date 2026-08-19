import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RIGHTS_FIELDS = [
    "is_anonymous",
    "can_manage_chat",
    "can_delete_messages",
    "can_manage_video_chats",
    "can_restrict_members",
    "can_promote_members",
    "can_change_info",
    "can_invite_users",
    "can_post_stories",
    "can_edit_stories",
    "can_delete_stories",
    "can_post_messages",
    "can_edit_messages",
    "can_pin_messages",
    "can_manage_topics",
]

TEXT_FIELDS = {
    "MyName": "name",
    "MyDescription": "description",
    "MyShortDescription": "short_description",
}

state = {}
log_path = os.environ["MOCK_LOG"]
reject = set(filter(None, os.environ.get("MOCK_REJECT", "").split(",")))


def bot_state(token):
    return state.setdefault(
        token,
        {
            "text": {},
            "commands": {},
            "rights": {},
            "menu": {},
        },
    )


def record(token, method, payload):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(
            json.dumps({"token": token, "method": method, "payload": payload}) + "\n"
        )


def default_rights():
    return {field: False for field in RIGHTS_FIELDS}


def handle(token, method, payload):
    bot = bot_state(token)

    for suffix, field in TEXT_FIELDS.items():
        if method == "get" + suffix:
            lang = payload.get("language_code", "")
            value = bot["text"].get((field, lang))
            if value is None:
                value = bot["text"].get((field, ""), "")
            return {field: value}
        if method == "set" + suffix:
            lang = payload.get("language_code", "")
            bot["text"][(field, lang)] = payload.get(field, "")
            return True

    if method == "getMyCommands":
        key = (json.dumps(payload.get("scope", {}), sort_keys=True), payload.get("language_code", ""))
        return bot["commands"].get(key, [])
    if method == "setMyCommands":
        key = (json.dumps(payload.get("scope", {}), sort_keys=True), payload.get("language_code", ""))
        bot["commands"][key] = payload.get("commands", [])
        return True

    if method == "getMyDefaultAdministratorRights":
        return bot["rights"].get(bool(payload.get("for_channels", False)), default_rights())
    if method == "setMyDefaultAdministratorRights":
        bot["rights"][bool(payload.get("for_channels", False))] = payload.get("rights", {})
        return True

    if method == "getChatMenuButton":
        return bot["menu"].get(str(payload.get("chat_id")), {"type": "default"})
    if method == "setChatMenuButton":
        bot["menu"][str(payload.get("chat_id"))] = payload.get("menu_button", {})
        return True

    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self.reply(400, {"ok": False, "error_code": 400, "description": "Bad Request: invalid JSON"})
            return

        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or not parts[0].startswith("bot"):
            self.reply(404, {"ok": False, "error_code": 404, "description": "Not Found"})
            return

        token = parts[0][3:]
        method = parts[1]
        record(token, method, payload)

        if token in reject:
            self.reply(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})
            return

        result = handle(token, method, payload)
        if result is None:
            self.reply(404, {"ok": False, "error_code": 404, "description": "Not Found: method not found"})
            return

        self.reply(200, {"ok": True, "result": result})


def main():
    port = int(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    with open(os.environ["MOCK_READY"], "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    server.serve_forever()


main()
