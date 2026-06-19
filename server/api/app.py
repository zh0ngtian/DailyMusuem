from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from .db import MuseumDatabaseError
from .routes import router


app = FastAPI(title="MuseumMuse API", version="1")
app.include_router(router)


@app.exception_handler(MuseumDatabaseError)
async def database_error_handler(request: Request, exc: MuseumDatabaseError) -> JSONResponse:
    return JSONResponse(
        status_code=503,
        content={"error": {"code": "database_unavailable", "message": str(exc)}},
    )


@app.exception_handler(HTTPException)
async def http_error_handler(request: Request, exc: HTTPException) -> JSONResponse:
    if isinstance(exc.detail, dict) and "code" in exc.detail and "message" in exc.detail:
        payload = exc.detail
    elif isinstance(exc.detail, dict) and "error" in exc.detail:
        return JSONResponse(status_code=exc.status_code, content=exc.detail)
    else:
        payload = {"code": "request_failed", "message": str(exc.detail)}
    return JSONResponse(status_code=exc.status_code, content={"error": payload})
