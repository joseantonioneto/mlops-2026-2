from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.integration

CORPO = {"nome": "Ana", "text": "não entendi nada"}


def test_raiz_responde_ok(client, monkeypatch):
    monkeypatch.delenv("APP_VERSION", raising=False)
    resposta = client.get("/")
    assert resposta.status_code == 200
    assert resposta.json() == {"status": "ok", "version": "dev"}


def test_raiz_devolve_a_versao_do_ambiente(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v9.9.9")
    assert client.get("/").json() == {"status": "ok", "version": "v9.9.9"}


def test_post_predictions_devolve_predicao_de_cada_modelo_e_mensagem(client):
    resposta = client.post("/predictions", json=CORPO)

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert set(corpo) == {"modelo_a", "modelo_b", "message"}
    assert corpo["modelo_a"]["intent"] == "confusion"
    assert corpo["modelo_a"]["probs"]["confusion"] == 0.9
    assert corpo["message"]["nome"] == "Ana"
    assert corpo["message"]["text"] == "não entendi nada"
    assert "_id" not in corpo


def test_post_predictions_grava_predicoes_e_mensagem_no_banco(client, colecao):
    client.post("/predictions", json=CORPO)

    assert colecao.count_documents({}) == 1
    doc = colecao.find_one()
    assert doc["message"]["text"] == "não entendi nada"
    assert doc["modelo_a"]["intent"] == "confusion"


def test_post_predictions_rejeita_texto_vazio(client, colecao):
    resposta = client.post("/predictions", json={"nome": "Ana", "text": ""})
    assert resposta.status_code == 422
    assert colecao.count_documents({}) == 0


def test_post_predictions_rejeita_sem_texto(client):
    resposta = client.post("/predictions", json={"nome": "Ana"})
    assert resposta.status_code == 422


def _enviar_com_data(client, texto, quando):
    client.post("/predictions", json={"text": texto, "timestamp": quando.isoformat()})


def test_get_predictions_devolve_mais_recentes_primeiro(client):
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    _enviar_com_data(client, "antiga", base)
    _enviar_com_data(client, "nova", base + timedelta(hours=1))

    resposta = client.get("/predictions")

    assert resposta.status_code == 200
    textos = [item["message"]["text"] for item in resposta.json()]
    assert textos == ["nova", "antiga"]


def test_get_predictions_respeita_limit(client):
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    for i in range(3):
        _enviar_com_data(client, f"msg{i}", base + timedelta(minutes=i))

    resposta = client.get("/predictions", params={"limit": 2})

    assert len(resposta.json()) == 2


def test_get_predictions_nao_vaza_id_do_mongo(client):
    client.post("/predictions", json=CORPO)
    itens = client.get("/predictions").json()
    assert itens and all("_id" not in item for item in itens)
