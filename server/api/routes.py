from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from .auth import (
    AuthChallengeDTO,
    AuthSessionDTO,
    DebugAuthRegistrationDTO,
    DebugAuthRegistrationRequest,
    DebugAuthSessionRequest,
    issue_challenge,
    issue_debug_session,
    register_debug_device,
    require_business_auth,
)
from .db import MuseumDatabase, MuseumDatabaseError
from .models import ArtworkPageDTO, HealthDTO, WidgetCandidateDTO


router = APIRouter()
database = MuseumDatabase()


def envelope(data: object) -> dict[str, object]:
    return {"dataVersion": database.data_version(), "data": data}


def parse_csv(raw_value: str | None) -> list[str]:
    if not raw_value:
        return []
    return [part.strip() for part in raw_value.split(",") if part.strip()]


@router.get("/health")
async def health() -> HealthDTO:
    readable = database.health()
    return HealthDTO(ok=readable, databaseReadable=readable, dataVersion=database.data_version())


@router.post("/v1/auth/challenge")
async def auth_challenge(request: Request) -> AuthChallengeDTO:
    return issue_challenge(request)


@router.post("/v1/auth/register")
async def auth_register(request: Request, payload: DebugAuthRegistrationRequest) -> DebugAuthRegistrationDTO:
    return register_debug_device(request, payload)


@router.post("/v1/auth/session")
async def auth_session(request: Request, payload: DebugAuthSessionRequest) -> AuthSessionDTO:
    return issue_debug_session(request, payload)


@router.get("/v1/museums", dependencies=[Depends(require_business_auth)])
async def museums() -> dict[str, object]:
    return envelope(database.museums())


@router.get("/v1/museums/metadata", dependencies=[Depends(require_business_auth)])
async def museum_metadata() -> dict[str, object]:
    return envelope(database.museum_metadata())


@router.get("/v1/museums/{museum_id}/categories", dependencies=[Depends(require_business_auth)])
async def museum_categories(museum_id: str, source: str | None = None) -> dict[str, object]:
    try:
        return envelope(database.categories(museum_id, source))
    except MuseumDatabaseError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.get("/v1/museums/{museum_id}/artworks", dependencies=[Depends(require_business_auth)])
async def museum_artworks(
    museum_id: str,
    source: str | None = None,
    category_ids: str | None = None,
    limit: int = Query(default=10, ge=1, le=50),
    cursor: str | None = None,
    order: str = Query(default="stable", pattern="^(stable|random)$"),
    seed: int | None = None,
    has_image: bool = True,
) -> dict[str, object]:
    try:
        items, next_cursor, has_more = database.artworks(
            museum_id=museum_id,
            source=source,
            category_ids=parse_csv(category_ids),
            limit=limit,
            cursor=cursor,
            order=order,
            seed=seed,
            has_image=has_image,
        )
    except MuseumDatabaseError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    return envelope(ArtworkPageDTO(items=items, nextCursor=next_cursor, hasMore=has_more))


@router.get("/v1/museums/{museum_id}/artworks/{object_id}", dependencies=[Depends(require_business_auth)])
async def museum_artwork(museum_id: str, object_id: str, source: str | None = None) -> dict[str, object]:
    try:
        artwork = database.artwork(museum_id, object_id, source)
    except MuseumDatabaseError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    if artwork is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "artwork_not_found", "message": "Artwork not found."},
        )
    return envelope(artwork)


@router.get("/v1/widget/candidate", dependencies=[Depends(require_business_auth)])
async def widget_candidate(
    scope: str,
    source: str | None = None,
    category_ids: str | None = None,
    exclude_keys: str | None = None,
) -> dict[str, object]:
    museum_ids = [museum.museumID for museum in database.museums() if museum.supportsWidgetContent]
    if scope.startswith("single:"):
        museum_ids = [scope.removeprefix("single:")]
    elif scope != "all":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid widget scope")

    excluded = set(parse_csv(exclude_keys))
    categories = parse_csv(category_ids)
    for museum_id in museum_ids:
        items, _, _ = database.artworks(
            museum_id=museum_id,
            source=source,
            category_ids=categories,
            limit=10,
            cursor=None,
            order="random",
            seed=None,
            has_image=True,
        )
        for artwork in items:
            if f"{artwork.museumID}|{artwork.objectID}" not in excluded:
                return envelope(WidgetCandidateDTO(artwork=artwork))

    return envelope(WidgetCandidateDTO(artwork=None))
