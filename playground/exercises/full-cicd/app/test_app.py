import app as demo


def client():
    demo.app.testing = True
    return demo.app.test_client()


def test_index_reports_app_and_version():
    body = client().get("/").get_json()
    assert body["app"] == "cicd-demo"
    assert "version" in body


def test_healthz_ok_by_default(monkeypatch):
    monkeypatch.delenv("MODE", raising=False)
    monkeypatch.delenv("KNOWN_BAD", raising=False)
    assert client().get("/healthz").status_code == 200


def test_known_bad_build_is_still_healthy_when_relaxed(monkeypatch):
    # Why the unit tests cannot catch a prod-only failure: they run relaxed.
    monkeypatch.setenv("MODE", "relaxed")
    monkeypatch.setenv("KNOWN_BAD", "true")
    assert client().get("/healthz").status_code == 200


def test_known_bad_build_is_unhealthy_when_strict(monkeypatch):
    monkeypatch.setenv("MODE", "strict")
    monkeypatch.setenv("KNOWN_BAD", "true")
    assert client().get("/healthz").status_code == 500
