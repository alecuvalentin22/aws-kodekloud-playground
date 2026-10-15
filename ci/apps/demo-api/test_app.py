import app as demo


def client():
    demo.app.testing = True
    return demo.app.test_client()


def test_index_reports_app_and_version():
    body = client().get("/").get_json()
    assert body["app"] == "demo-api"
    assert "version" in body


def test_healthz_ok_by_default(monkeypatch):
    monkeypatch.delenv("FAIL_HEALTH", raising=False)
    assert client().get("/healthz").status_code == 200


def test_healthz_fails_when_told_to(monkeypatch):
    monkeypatch.setenv("FAIL_HEALTH", "true")
    assert client().get("/healthz").status_code == 500
