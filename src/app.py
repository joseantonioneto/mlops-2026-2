import os

from fastapi import FastAPI
from contextlib import asynccontextmanager

from src.modules.intent_classifier.controller import router as intent_clf_router
from src.modules.intent_classifier.service import load_models, clear_models

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Start up 
    load_models()
    yield
    # Close down
    clear_models()


app = FastAPI(
    title="API de MLOps",
    description='...',
    version='0.1.0',
    docs_url='/docs',
    lifespan=lifespan
) 

app.include_router(intent_clf_router)

@app.get('/')
def root():
    return {'status': 'ok', 'version': os.getenv('APP_VERSION', 'dev')}