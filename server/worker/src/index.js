const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8"
};

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const SIMPLE_AUTH_WINDOW_SECONDS = 10;

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      const path = url.pathname.replace(/\/+$/, "") || "/";

      if (request.method === "GET" && path === "/health") {
        const readable = await databaseReadable(env.DB);
        return jsonResponse({
          ok: readable,
          databaseReadable: readable,
          dataVersion: await dataVersion(env)
        });
      }

      if (request.method === "POST" && path.startsWith("/v1/auth/")) {
        return authUnavailable();
      }

      const authError = await requireBusinessAuth(request, env);
      if (authError) {
        return authError;
      }

      if (request.method === "GET" && path === "/v1/museums") {
        return envelopeResponse(env, await museums(env.DB));
      }

      const categoriesMatch = path.match(/^\/v1\/museums\/([^/]+)\/categories$/);
      if (request.method === "GET" && categoriesMatch) {
        const museumID = decodeURIComponent(categoriesMatch[1]);
        const source = optionalParam(url, "source");
        return envelopeResponse(env, await categories(env.DB, museumID, source));
      }

      const artworksMatch = path.match(/^\/v1\/museums\/([^/]+)\/artworks$/);
      if (request.method === "GET" && artworksMatch) {
        const museumID = decodeURIComponent(artworksMatch[1]);
        const page = await artworkPage(env.DB, {
          museumID,
          source: optionalParam(url, "source"),
          categoryIDs: parseCSV(url.searchParams.get("category_ids")),
          limit: parseLimit(url.searchParams.get("limit")),
          cursor: optionalParam(url, "cursor"),
          order: parseOrder(url.searchParams.get("order")),
          seed: parseOptionalInt(url.searchParams.get("seed")),
          onlyOnView: parseBool(url.searchParams.get("only_on_view"), false),
          hasImage: parseBool(url.searchParams.get("has_image"), true)
        });
        return envelopeResponse(env, page);
      }

      const artworkMatch = path.match(/^\/v1\/museums\/([^/]+)\/artworks\/(.+)$/);
      if (request.method === "GET" && artworkMatch) {
        const museumID = decodeURIComponent(artworkMatch[1]);
        const objectID = decodeURIComponent(artworkMatch[2]);
        const source = optionalParam(url, "source");
        const artwork = await artworkDetail(env.DB, museumID, objectID, source);
        if (!artwork) {
          return errorResponse(404, "artwork_not_found", "Artwork not found.");
        }
        return envelopeResponse(env, artwork);
      }

      if (request.method === "GET" && path === "/v1/widget/candidate") {
        const candidate = await widgetCandidate(env.DB, {
          scope: requiredParam(url, "scope"),
          source: optionalParam(url, "source"),
          categoryIDs: parseCSV(url.searchParams.get("category_ids")),
          excludeKeys: new Set(parseCSV(url.searchParams.get("exclude_keys")))
        });
        return envelopeResponse(env, { artwork: candidate });
      }

      return errorResponse(404, "not_found", "Route not found.");
    } catch (error) {
      if (error instanceof HttpError) {
        return errorResponse(error.status, error.code, error.message);
      }
      console.error(JSON.stringify({ level: "error", message: "Unhandled request failure", error: String(error) }));
      return errorResponse(500, "internal_server_error", "Internal server error.");
    }
  }
};

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

async function requireBusinessAuth(request, env) {
  const mode = String(env.AUTH_MODE || "").trim().toLowerCase();
  if (mode === "disabled") {
    return null;
  }
  if (mode === "simple") {
    return requireSimpleAuth(request, env);
  }

  const authorization = request.headers.get("authorization") || "";
  const requiredHeadersPresent = [
    authorization.startsWith("Bearer "),
    request.headers.has("x-museummuse-timestamp"),
    request.headers.has("x-museummuse-nonce"),
    request.headers.has("x-museummuse-request-hash"),
    request.headers.has("x-museummuse-app-attest-keyid"),
    request.headers.has("x-museummuse-app-attest-assertion"),
    request.headers.has("x-museummuse-app-version")
  ].every(Boolean);

  if (!requiredHeadersPresent) {
    return errorResponse(401, "authentication_required", "Authentication is required.");
  }

  return errorResponse(501, "app_attest_not_configured", "App Attest verification is not configured for this server.");
}

async function requireSimpleAuth(request, env) {
  const authorization = request.headers.get("authorization") || "";
  const timestamp = request.headers.get("x-museummuse-timestamp") || "";
  const nonce = request.headers.get("x-museummuse-nonce") || "";
  const requestHash = request.headers.get("x-museummuse-request-hash") || "";
  const appVersion = request.headers.get("x-museummuse-app-version") || "";
  const requiredHeadersPresent = [
    authorization.startsWith("Bearer "),
    timestamp.length > 0,
    nonce.length > 0,
    requestHash.length > 0,
    appVersion.length > 0
  ].every(Boolean);

  if (!requiredHeadersPresent) {
    return errorResponse(401, "authentication_required", "Authentication is required.");
  }

  const secret = simpleAuthSecret(env);
  if (!secret) {
    return errorResponse(503, "simple_auth_secret_missing", "SIMPLE_AUTH_SECRET or MUSEUMMUSE_SIMPLE_AUTH_SECRET is required in simple auth mode.");
  }

  const requestTime = Number(timestamp);
  if (!Number.isInteger(requestTime)) {
    return errorResponse(401, "invalid_timestamp", "Invalid request timestamp.");
  }
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - requestTime) > SIMPLE_AUTH_WINDOW_SECONDS) {
    return errorResponse(401, "expired_request", "Request timestamp is outside the allowed window.");
  }

  const expectedHash = await canonicalRequestHash(request, timestamp, nonce);
  if (!constantTimeEqual(requestHash, expectedHash)) {
    return errorResponse(401, "invalid_request_hash", "Request hash does not match request.");
  }

  const expectedSignature = await hmacHex(secret, requestHash);
  const actualSignature = authorization.replace(/^Bearer\s+/i, "").trim();
  if (!constantTimeEqual(actualSignature, expectedSignature)) {
    return errorResponse(401, "invalid_signature", "Invalid auth signature.");
  }

  const replayError = await consumeSimpleNonce(env, nonce, now);
  if (replayError) {
    return replayError;
  }
  return null;
}

function simpleAuthSecret(env) {
  const secret = String(env.MUSEUMMUSE_SIMPLE_AUTH_SECRET || env.SIMPLE_AUTH_SECRET || "").trim();
  return secret.length > 0 ? secret : null;
}

async function canonicalRequestHash(request, timestamp, nonce) {
  const url = new URL(request.url);
  const queryPairs = Array.from(url.searchParams.entries()).sort((lhs, rhs) => {
    if (lhs[0] === rhs[0]) {
      return lhs[1] < rhs[1] ? -1 : lhs[1] > rhs[1] ? 1 : 0;
    }
    return lhs[0] < rhs[0] ? -1 : 1;
  });
  const canonicalQuery = queryPairs
    .map(([name, value]) => `${formURLEncoded(name)}=${formURLEncoded(value)}`)
    .join("&");
  const bodyHash = await sha256Hex(new Uint8Array(await request.clone().arrayBuffer()));
  const canonical = [
    request.method.toUpperCase(),
    canonicalPathname(url),
    canonicalQuery,
    bodyHash,
    timestamp,
    nonce
  ].join("\n");
  return sha256Hex(textEncoder.encode(canonical));
}

function canonicalPathname(url) {
  try {
    return decodeURI(url.pathname);
  } catch {
    return url.pathname;
  }
}

async function hmacHex(secret, value) {
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, textEncoder.encode(value))));
}

async function sha256Hex(data) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", data)));
}

function formURLEncoded(value) {
  return encodeURIComponent(value)
    .replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)
    .replace(/%20/g, "+");
}

function hex(bytes) {
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function consumeSimpleNonce(env, nonce, now) {
  if (!env.DB) {
    return errorResponse(503, "nonce_store_unavailable", "Nonce store is unavailable.");
  }
  const key = `simple:${nonce}`;
  await env.DB.prepare(
    `CREATE TABLE IF NOT EXISTS auth_nonces (
      nonce TEXT PRIMARY KEY,
      expires_at INTEGER NOT NULL
    )`
  ).run();
  await env.DB.prepare("DELETE FROM auth_nonces WHERE expires_at <= ?").bind(now).run();
  const result = await env.DB.prepare("INSERT OR IGNORE INTO auth_nonces (nonce, expires_at) VALUES (?, ?)")
    .bind(key, now + SIMPLE_AUTH_WINDOW_SECONDS)
    .run();
  if (Number(result.meta?.changes ?? 1) === 0) {
    return errorResponse(401, "replayed_request", "Request nonce has already been used.");
  }
  return null;
}

function constantTimeEqual(lhs, rhs) {
  if (lhs.length !== rhs.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < lhs.length; index += 1) {
    difference |= lhs.charCodeAt(index) ^ rhs.charCodeAt(index);
  }
  return difference === 0;
}

function authUnavailable() {
  return errorResponse(403, "debug_auth_unavailable", "Debug auth is not enabled for this Worker deployment.");
}

async function databaseReadable(db) {
  try {
    await db.prepare("SELECT 1").first();
    return true;
  } catch {
    return false;
  }
}

async function envelopeResponse(env, data) {
  return jsonResponse({
    dataVersion: await dataVersion(env),
    data
  });
}

async function dataVersion(env) {
  const configured = String(env.DATA_VERSION || "").trim();
  if (configured) {
    return configured;
  }

  try {
    const row = await env.DB.prepare(
      "SELECT finished_at FROM crawl_runs WHERE finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT 1"
    ).first();
    return row?.finished_at ? String(row.finished_at) : "unknown";
  } catch {
    return "unknown";
  }
}

async function museums(db) {
  const result = await db.prepare(
    `SELECT museum_id, display_name, country, city, subtitle, supports_widget_content
     FROM museums
     ORDER BY sort_order, museum_id`
  ).all();
  return rows(result).map((row) => ({
    museumID: row.museum_id,
    displayName: row.display_name,
    country: row.country,
    city: row.city,
    subtitle: row.subtitle,
    supportsWidgetContent: Boolean(row.supports_widget_content)
  }));
}

async function categories(db, museumID, source) {
  const sourceKey = await resolveSourceKey(db, museumID, source);
  const result = await db.prepare(
    `SELECT museum_id, category_id, display_name, kind, remote_value
     FROM categories
     WHERE museum_id = ? AND source_key = ?
     ORDER BY sort_order, category_id`
  ).bind(museumID, sourceKey).all();
  return rows(result).map((row) => ({
    museumID: row.museum_id,
    id: row.category_id,
    displayName: row.display_name,
    kind: row.kind,
    remoteValue: row.remote_value ?? null
  }));
}

async function artworkDetail(db, museumID, objectID, source) {
  const sourceKey = await resolveDetailSourceKey(db, museumID, objectID, source);
  const row = await db.prepare(
    `SELECT *
     FROM artworks
     WHERE museum_id = ? AND source_key = ? AND object_id = ?
     LIMIT 1`
  ).bind(museumID, sourceKey, objectID).first();
  if (!row) {
    return null;
  }
  const images = await imagesForArtworks(db, [row.artwork_pk]);
  return artworkDTO(row, images.get(row.artwork_pk) || {});
}

async function artworkPage(db, query) {
  const sourceKey = await resolveSourceKey(db, query.museumID, query.source);
  const limit = Math.min(Math.max(query.limit, 1), 50);
  const filterHash = await makeFilterHash({
    museum_id: query.museumID,
    source_key: sourceKey,
    category_ids: query.categoryIDs,
    order: query.order,
    seed: query.seed,
    only_on_view: query.onlyOnView,
    has_image: query.hasImage
  });
  const offset = query.cursor ? decodeCursor(query.cursor, filterHash).offset : 0;

  const params = [query.museumID, sourceKey];
  const where = ["a.museum_id = ?", "a.source_key = ?"];
  const joins = [];

  if (query.hasImage) {
    where.push("a.has_image = 1");
  }
  if (query.museumID === "met" && query.onlyOnView) {
    where.push("a.is_on_view = 1");
  }
  if (query.categoryIDs.length > 0) {
    joins.push(
      `JOIN artwork_categories ac ON ac.artwork_pk = a.artwork_pk
       JOIN categories c ON c.category_pk = ac.category_pk`
    );
    where.push(`c.category_id IN (${query.categoryIDs.map(() => "?").join(", ")})`);
    params.push(...query.categoryIDs);
  }

  let orderSQL = "a.object_id, a.artwork_pk";
  if (query.order === "random") {
    const effectiveSeed = Number.isFinite(query.seed) ? Number(query.seed) : 1;
    orderSQL = `((a.artwork_pk * 1103515245 + ${effectiveSeed}) & 2147483647), a.artwork_pk`;
  }

  const sql = `
    SELECT DISTINCT a.*
    FROM artworks a
    ${joins.join(" ")}
    WHERE ${where.join(" AND ")}
    ORDER BY ${orderSQL}
    LIMIT ? OFFSET ?`;

  params.push(limit + 1, offset);
  const result = await db.prepare(sql).bind(...params).all();
  const pageRows = rows(result).slice(0, limit);
  const images = await imagesForArtworks(db, pageRows.map((row) => row.artwork_pk));
  const hasMore = rows(result).length > limit;

  return {
    items: pageRows.map((row) => artworkDTO(row, images.get(row.artwork_pk) || {})),
    nextCursor: hasMore ? encodeCursor({
      offset: offset + limit,
      order: query.order,
      seed: query.seed,
      filterHash
    }) : null,
    hasMore
  };
}

async function widgetCandidate(db, query) {
  let museumIDs = (await museums(db))
    .filter((museum) => museum.supportsWidgetContent)
    .map((museum) => museum.museumID);

  if (query.scope.startsWith("single:")) {
    museumIDs = [query.scope.slice("single:".length)];
  } else if (query.scope !== "all") {
    throw new HttpError(400, "request_failed", "Invalid widget scope");
  }

  for (const museumID of museumIDs) {
    const page = await artworkPage(db, {
      museumID,
      source: museumID === "nnm" ? query.source : null,
      categoryIDs: query.categoryIDs,
      limit: 10,
      cursor: null,
      order: "random",
      seed: null,
      onlyOnView: false,
      hasImage: true
    });
    const match = page.items.find((artwork) => !query.excludeKeys.has(`${artwork.museumID}|${artwork.objectID}`));
    if (match) {
      return match;
    }
  }

  return null;
}

async function resolveSourceKey(db, museumID, source) {
  if (museumID === "nnm" && (source === "official" || source === "colbase")) {
    return source;
  }

  const row = await db.prepare(
    `SELECT source_key
     FROM data_sources
     WHERE museum_id = ? AND (? IS NULL OR source_key = ?)
     ORDER BY is_default DESC, source_key
     LIMIT 1`
  ).bind(museumID, source, source).first();

  if (!row) {
    throw new HttpError(400, "request_failed", `Unknown source for museum=${museumID}: ${source || "default"}`);
  }
  return String(row.source_key);
}

async function resolveDetailSourceKey(db, museumID, objectID, source) {
  if (museumID === "nnm" && source === null) {
    return objectID.startsWith("narahaku-") ? "official" : "colbase";
  }
  return resolveSourceKey(db, museumID, source);
}

async function imagesForArtworks(db, artworkPKs) {
  if (artworkPKs.length === 0) {
    return new Map();
  }

  const result = await db.prepare(
    `SELECT artwork_pk, role, url
     FROM artwork_images
     WHERE artwork_pk IN (${artworkPKs.map(() => "?").join(", ")})
     ORDER BY sort_order, image_pk`
  ).bind(...artworkPKs).all();

  const images = new Map();
  for (const row of rows(result)) {
    const artworkPK = row.artwork_pk;
    const perArtwork = images.get(artworkPK) || {};
    if (row.role === "primary" && !perArtwork.primary) {
      perArtwork.primary = String(row.url);
    } else if (row.role === "thumbnail" && !perArtwork.thumbnail) {
      perArtwork.thumbnail = String(row.url);
    }
    images.set(artworkPK, perArtwork);
  }
  return images;
}

function artworkDTO(row, images) {
  return {
    id: row.stable_id,
    museumID: row.museum_id,
    sourceKey: row.source_key,
    objectID: row.object_id,
    title: row.title,
    artworkDescription: row.artwork_description_html || row.artwork_description_text || null,
    artistDisplayName: row.artist_display_name || null,
    objectDate: row.object_date || null,
    medium: row.medium || null,
    dimensions: row.dimensions || null,
    department: row.department || null,
    culture: row.culture || null,
    country: row.country || null,
    repository: row.repository || null,
    primaryImageURL: images.primary || null,
    primaryImageSmallURL: images.thumbnail || images.primary || null,
    objectURL: row.object_url || null
  };
}

async function makeFilterHash(values) {
  const payload = stableStringify(values);
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(payload));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function encodeCursor(payload) {
  return base64URL(textEncoder.encode(JSON.stringify(payload)));
}

function decodeCursor(rawValue, expectedFilterHash) {
  try {
    const payload = JSON.parse(textDecoder.decode(base64URLDecode(rawValue)));
    if (payload.filterHash !== expectedFilterHash) {
      throw new HttpError(400, "request_failed", "Cursor does not match current filters");
    }
    return {
      offset: Number(payload.offset) || 0,
      order: String(payload.order || "stable"),
      seed: payload.seed ?? null,
      filterHash: payload.filterHash
    };
  } catch (error) {
    if (error instanceof HttpError) {
      throw error;
    }
    throw new HttpError(400, "request_failed", "Invalid cursor");
  }
}

function base64URL(bytes) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64URLDecode(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function rows(result) {
  return Array.isArray(result?.results) ? result.results : [];
}

function optionalParam(url, name) {
  const value = url.searchParams.get(name);
  const trimmed = value?.trim() || "";
  return trimmed ? trimmed : null;
}

function requiredParam(url, name) {
  const value = optionalParam(url, name);
  if (!value) {
    throw new HttpError(400, "request_failed", `Missing required query parameter: ${name}`);
  }
  return value;
}

function parseCSV(rawValue) {
  if (!rawValue) {
    return [];
  }
  return rawValue.split(",").map((part) => part.trim()).filter(Boolean);
}

function parseLimit(rawValue) {
  if (!rawValue) {
    return 10;
  }
  const value = Number.parseInt(rawValue, 10);
  if (!Number.isFinite(value)) {
    throw new HttpError(400, "request_failed", "Invalid limit");
  }
  return Math.min(Math.max(value, 1), 50);
}

function parseOrder(rawValue) {
  const value = rawValue || "stable";
  if (value !== "stable" && value !== "random") {
    throw new HttpError(400, "request_failed", "Invalid order");
  }
  return value;
}

function parseOptionalInt(rawValue) {
  if (rawValue === null || rawValue.trim() === "") {
    return null;
  }
  const value = Number.parseInt(rawValue, 10);
  if (!Number.isFinite(value)) {
    throw new HttpError(400, "request_failed", "Invalid integer value");
  }
  return value;
}

function parseBool(rawValue, defaultValue) {
  if (rawValue === null || rawValue.trim() === "") {
    return defaultValue;
  }
  return ["1", "true", "yes"].includes(rawValue.trim().toLowerCase());
}

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: JSON_HEADERS
  });
}

function errorResponse(status, code, message) {
  return jsonResponse({ error: { code, message } }, status);
}
