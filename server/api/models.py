from pydantic import BaseModel, Field


class ErrorPayload(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    error: ErrorPayload


class Envelope(BaseModel):
    dataVersion: str
    data: object


class MuseumDTO(BaseModel):
    museumID: str
    displayName: str
    country: str
    city: str
    subtitle: str
    supportsWidgetContent: bool


class MuseumIconDTO(BaseModel):
    url: str | None = None
    assetName: str | None = None
    backgroundColor: str | None = None


class MuseumCapabilitiesDTO(BaseModel):
    supportsWidgetContent: bool
    supportsTranslation: bool
    supportsFavorites: bool


class MuseumSourceDTO(BaseModel):
    sourceKey: str
    displayName: str
    isDefault: bool
    translationSourceLanguage: str | None = None
    preferredImageURLOrder: list[str] = Field(default_factory=list)
    imageRequestHeaders: dict[str, str] = Field(default_factory=dict)


class MuseumMetadataCategoryDTO(BaseModel):
    sourceKey: str
    categoryID: str
    displayName: str
    sortOrder: int


class WaterfallImageFetchPolicyDTO(BaseModel):
    qps: float | None = None


class MuseumMetadataDTO(BaseModel):
    museumID: str
    displayName: str
    subtitle: str
    country: str
    city: str
    address: str | None = None
    textPunctuationStyle: str
    icon: MuseumIconDTO
    sortOrder: int
    capabilities: MuseumCapabilitiesDTO
    defaultSourceKey: str
    sources: list[MuseumSourceDTO]
    categories: list[MuseumMetadataCategoryDTO]
    waterfallImageFetchPolicy: WaterfallImageFetchPolicyDTO


class MuseumMetadataDataDTO(BaseModel):
    museums: list[MuseumMetadataDTO]


class MuseumCategoryDTO(BaseModel):
    museumID: str
    id: str
    displayName: str


class ArtworkDTO(BaseModel):
    id: str
    museumID: str
    sourceKey: str | None = None
    objectID: str
    title: str
    artworkDescription: str | None = None
    artistDisplayName: str | None = None
    objectDate: str | None = None
    medium: str | None = None
    dimensions: str | None = None
    department: str | None = None
    culture: str | None = None
    country: str | None = None
    repository: str | None = None
    primaryImageURL: str | None = None
    primaryImageSmallURL: str | None = None
    objectURL: str | None = None


class ArtworkPageDTO(BaseModel):
    items: list[ArtworkDTO]
    nextCursor: str | None = None
    hasMore: bool = False


class HealthDTO(BaseModel):
    ok: bool
    databaseReadable: bool
    dataVersion: str


class WidgetCandidateDTO(BaseModel):
    artwork: ArtworkDTO | None = None


class CursorPayload(BaseModel):
    offset: int = Field(ge=0)
    order: str
    seed: int | None = None
    filterHash: str
