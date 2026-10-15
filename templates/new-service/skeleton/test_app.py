from app import app


def test_index():
    body = app.test_client().get("/").get_json()
    assert body["app"] == "${{ values.name }}"


def test_healthz():
    assert app.test_client().get("/healthz").status_code == 200
