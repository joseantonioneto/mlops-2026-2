"""Teste de fumaca contra a API REAL (ex.: container do docker compose).

Rode com: E2E_BASE_URL=http://localhost:8000 python -m pytest -m e2e
"""
import os
import uuid

import httpx
import pytest

pytestmark = pytest.mark.e2e

BASE_URL = os.environ.get("E2E_BASE_URL", "").rstrip("/")
TIMEOUT = 60  # a primeira predicao pode demorar (modelo carregando)

if not BASE_URL:
    pytest.skip("E2E_BASE_URL nao definida", allow_module_level=True)


def test_raiz_responde_ok():
    resposta = httpx.get(f"{BASE_URL}/", timeout=TIMEOUT)
    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["status"] == "ok"
    assert "version" in corpo  # APP_VERSION, ou "dev" quando a variavel nao existe


def test_predicao_e_gravada_no_mongo_real():
    texto = f"não entendi nada {uuid.uuid4().hex[:8]}"  # identifica esta execucao
    resposta = httpx.post(f"{BASE_URL}/predictions",
                          json={"nome": "CI", "text": texto}, timeout=TIMEOUT)

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["message"]["nome"] == "CI"
    modelos = {k: v for k, v in corpo.items() if k != "message"}
    assert modelos, "nenhum modelo respondeu"
    for resultado in modelos.values():
        assert isinstance(resultado["intent"], str)
        probs = resultado["probs"]
        assert all(isinstance(p, float) for p in probs.values())
        assert sum(probs.values()) == pytest.approx(1.0, abs=0.01)

    # Se aparece no GET, entao foi gravado de fato no banco.
    historico = httpx.get(f"{BASE_URL}/predictions", params={"limit": 5},
                          timeout=TIMEOUT)
    assert historico.status_code == 200
    textos = [item["message"]["text"] for item in historico.json()]
    assert texto in textos
