import json
import threading
import unittest
import urllib.error
import urllib.request

import app


def call(port, path, body=None):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
                                 data=None if body is None else json.dumps(body).encode(),
                                 method="GET" if body is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


class NotesApi(unittest.TestCase):
    def serve(self, **env):
        srv = app.make_server(app.load_config(env), 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv.server_address[1]

    def test_health(self):
        self.assertEqual(call(self.serve(), "/healthz"), (200, {"status": "ok"}))

    def test_note_length_is_config_driven(self):
        port = self.serve(MAX_NOTE_LENGTH="5")
        self.assertEqual(call(port, "/notes", {"text": "hello"})[0], 201)
        self.assertEqual(call(port, "/notes", {"text": "hello!"})[0], 413)

    def test_read_only(self):
        self.assertEqual(call(self.serve(READ_ONLY="true"), "/notes", {"text": "x"})[0], 403)

    def test_bad_config_stops_startup(self):
        for env in ({"MAX_NOTE_LENGTH": "lots"}, {"READ_ONLY": "maybe"}, {"LOG_LEVEL": "loud"}):
            with self.assertRaises(SystemExit):
                app.load_config(env)


if __name__ == "__main__":
    unittest.main()
