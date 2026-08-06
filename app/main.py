import logging

from fastapi import FastAPI, HTTPException
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.db import engine

logger = logging.getLogger(__name__)

app = FastAPI(title="TaskFlow")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))

        return {
            "status": "ok",
            "checks": {"db": "ok"},
        }
    except SQLAlchemyError as err:
        logger.exception("Database readiness check failed")

    raise HTTPException(
        status_code=503,
        detail={
            "status": "unavailable",
            "checks": {"db": "fail"},
        },
    ) from err
