import app as svc


def client():
    svc.app.testing = True
    return svc.app.test_client()


def test_index_reports_app_and_version():
    body = client().get("/").get_json()
    assert body["app"] == "__REPO__"
    assert "version" in body


def test_healthz_ok():
    assert client().get("/healthz").status_code == 200
