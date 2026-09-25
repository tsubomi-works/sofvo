const functions = require("firebase-functions");
const admin = require("firebase-admin");
const crypto = require("crypto");
// Cloud Functions v1
const nodemailer = require("nodemailer");
// v5: 投稿いいね/コメント数 + フォロー数 + タイムラインいいね数の自動更新 Cloud Functions 追加

admin.initializeApp();

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Google Sheets 連携設定 (googleapis不使用 — 直接REST API)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
const GADGET_SHEET_ID = "1rOmyJWIwLnosJkJmM0Z6QMNGwem0qkt2BSUlZ1w5Aw4";
const VENUE_SHEET_ID = "1fAx4y_kVF526f-F9wm9FsE9hNKA3Ddn8fa2SRjB7hPs";
const PRIZE_SHEET_ID = "1oKPuTyyK0xQHE6h-9FAYe5MH52j3Eroe3WuKCChJInE";

async function getAccessToken() {
  // Firebase Admin SDK の組み込みクレデンシャルを使用
  // google-auth-library 不要 → デプロイ高速化
  const tokenResult = await admin.app().options.credential.getAccessToken();
  return tokenResult.access_token;
}

async function sheetsClear(spreadsheetId, range) {
  const token = await getAccessToken();
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}/values/${encodeURIComponent(range)}:clear`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
  });
  return res;
}

async function sheetsUpdate(spreadsheetId, range, values) {
  const token = await getAccessToken();
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}/values/${encodeURIComponent(range)}?valueInputOption=RAW`;
  const res = await fetch(url, {
    method: "PUT",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ values }),
  });
  if (!res.ok) throw new Error(`Sheets API error: ${res.status} ${await res.text()}`);
  return res.json();
}

async function sheetsAddSheet(spreadsheetId, sheetName) {
  const token = await getAccessToken();
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}:batchUpdate`;
  await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ requests: [{ addSheet: { properties: { title: sheetName } } }] }),
  });
}

async function sheetsRead(spreadsheetId, range) {
  const token = await getAccessToken();
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${spreadsheetId}/values/${encodeURIComponent(range)}`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`Sheets read error: ${res.status} ${await res.text()}`);
  const data = await res.json();
  return data.values || [];
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Amazon PA-API v5 共通ヘルパー
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const PAAPI_HOST = "webservices.amazon.co.jp";
const PAAPI_REGION = "us-west-2";
const PAAPI_SERVICE = "ProductAdvertisingAPI";

function getPartnerTag() {
  return process.env.AMAZON_PARTNER_TAG || null;
}

function makeAffiliateUrl(asin) {
  const tag = getPartnerTag();
  if (tag) {
    return `https://www.amazon.co.jp/dp/${asin}?tag=${tag}`;
  }
  return `https://www.amazon.co.jp/dp/${asin}`;
}

function hasPaapiCredentials() {
  return !!(
    process.env.AMAZON_ACCESS_KEY &&
    process.env.AMAZON_SECRET_KEY &&
    process.env.AMAZON_PARTNER_TAG
  );
}

function getCredentials() {
  const accessKey = process.env.AMAZON_ACCESS_KEY;
  const secretKey = process.env.AMAZON_SECRET_KEY;
  const partnerTag = process.env.AMAZON_PARTNER_TAG;

  if (!accessKey || !secretKey || !partnerTag) {
    throw new Error(
      "Amazon PA-API credentials not configured. " +
      "Set AMAZON_ACCESS_KEY, AMAZON_SECRET_KEY, AMAZON_PARTNER_TAG in .env"
    );
  }
  return { accessKey, secretKey, partnerTag };
}

/**
 * AWS Signature Version 4 で PA-API v5 リクエストに署名
 */
function signRequest(payload, target) {
  const { accessKey, secretKey } = getCredentials();

  const now = new Date();
  const amzDate = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const dateStamp = amzDate.substring(0, 8);

  const canonicalUri = "/paapi5/" + target.split(".").pop().toLowerCase();
  const canonicalQuerystring = "";

  const headers = {
    "content-encoding": "amz-1.0",
    "content-type": "application/json; charset=utf-8",
    "host": PAAPI_HOST,
    "x-amz-date": amzDate,
    "x-amz-target": `com.amazon.paapi5.v1.ProductAdvertisingAPIv1.${target}`,
  };

  const signedHeaders = Object.keys(headers).sort().join(";");
  const canonicalHeaders = Object.keys(headers)
    .sort()
    .map((k) => `${k}:${headers[k]}\n`)
    .join("");

  const payloadHash = crypto
    .createHash("sha256")
    .update(payload)
    .digest("hex");

  const canonicalRequest = [
    "POST",
    canonicalUri,
    canonicalQuerystring,
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");

  const credentialScope = `${dateStamp}/${PAAPI_REGION}/${PAAPI_SERVICE}/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    crypto.createHash("sha256").update(canonicalRequest).digest("hex"),
  ].join("\n");

  const signingKey = getSignatureKey(secretKey, dateStamp, PAAPI_REGION, PAAPI_SERVICE);
  const signature = crypto
    .createHmac("sha256", signingKey)
    .update(stringToSign)
    .digest("hex");

  headers["Authorization"] =
    `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`;

  return { headers, url: `https://${PAAPI_HOST}${canonicalUri}` };
}

function getSignatureKey(key, dateStamp, region, service) {
  let k = crypto.createHmac("sha256", "AWS4" + key).update(dateStamp).digest();
  k = crypto.createHmac("sha256", k).update(region).digest();
  k = crypto.createHmac("sha256", k).update(service).digest();
  k = crypto.createHmac("sha256", k).update("aws4_request").digest();
  return k;
}

/**
 * PA-API レスポンスからアイテム情報を抽出
 */
function extractItem(item) {
  const info = item.ItemInfo || {};
  const images = item.Images || {};

  const asin = item.ASIN || "";

  // 金額取得: DisplayAmount → Amount(数値)からフォーマット
  let price =
    item.Offers?.Listings?.[0]?.Price?.DisplayAmount ||
    item.Offers?.Summaries?.[0]?.LowestPrice?.DisplayAmount ||
    item.Offers?.Summaries?.[0]?.HighestPrice?.DisplayAmount ||
    null;

  // DisplayAmountがない場合、Amount(数値)から生成
  if (!price) {
    const amount =
      item.Offers?.Listings?.[0]?.Price?.Amount ||
      item.Offers?.Summaries?.[0]?.LowestPrice?.Amount ||
      item.Offers?.Summaries?.[0]?.HighestPrice?.Amount;
    const currency =
      item.Offers?.Listings?.[0]?.Price?.Currency ||
      item.Offers?.Summaries?.[0]?.LowestPrice?.Currency ||
      "JPY";
    if (amount != null) {
      price = currency === "JPY"
        ? `￥${Number(amount).toLocaleString()}`
        : `${currency} ${amount}`;
    }
  }

  return {
    asin,
    title: info.Title?.DisplayValue || "",
    imageUrl:
      images.Primary?.Large?.URL ||
      images.Primary?.Medium?.URL ||
      "",
    detailPageUrl: `https://www.amazon.co.jp/dp/${asin}`,
    affiliateUrl: makeAffiliateUrl(asin),
    price,
  };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// スクレイピング フォールバック
// PA-API認証情報が未設定の場合に使用
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// ランダムUser-Agent（Cloud FunctionsのIPブロック対策）
function randomUserAgent() {
  const agents = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  ];
  return agents[Math.floor(Math.random() * agents.length)];
}

async function scrapeAmazonSearch(keyword) {
  const url = `https://www.amazon.co.jp/s?k=${encodeURIComponent(keyword)}&language=ja_JP`;

  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 10000);
  const response = await fetch(url, {
    headers: {
      "User-Agent": randomUserAgent(),
      "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
      "Accept-Encoding": "gzip, deflate, br",
      "Cache-Control": "max-age=0",
      "Sec-Ch-Ua": '"Chromium";v="131", "Not_A Brand";v="24"',
      "Sec-Ch-Ua-Mobile": "?0",
      "Sec-Ch-Ua-Platform": '"Windows"',
      "Sec-Fetch-Dest": "document",
      "Sec-Fetch-Mode": "navigate",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-User": "?1",
      "Upgrade-Insecure-Requests": "1",
    },
    redirect: "follow",
    signal: ac.signal,
  }).finally(() => clearTimeout(tid));

  if (!response.ok) {
    throw new Error(`Amazon returned status ${response.status}`);
  }

  const html = await response.text();

  // CAPTCHA検出
  if (html.includes("captcha") || html.includes("robot") || html.includes("api-services-support@amazon.com")) {
    console.warn("[scrapeAmazonSearch] CAPTCHA/bot detection page received");
    throw new Error("Amazon bot detection triggered");
  }

  const cheerio = require("cheerio");
  const $ = cheerio.load(html);
  const items = [];

  // 検索結果の総件数をHTMLテキストからregexで抽出
  let totalResults = 0;
  // Amazon.co.jp patterns:
  //   "1,000以上の結果" / "10,000 以上の結果"
  //   "1-48 of over 1,000 results" / "of 500 results"
  //   "1,000件中" / "500 件の結果"
  const countPatterns = [
    /([\d,，]+)\s*以上の結果/,
    /([\d,，]+)\s*件以上の結果/,
    /([\d,，]+)\s*件中/,
    /([\d,，]+)\s*件の結果/,
    /of\s+over\s+([\d,]+)\s+result/,
    /of\s+([\d,]+)\s+result/,
    />([\d,，]+)\s*以上</, // inside HTML tags
    />([\d,，]+)\s*件</,
  ];
  for (const pat of countPatterns) {
    const m = html.match(pat);
    if (m) {
      totalResults = parseInt(m[1].replace(/[,，]/g, ""), 10);
      if (totalResults > 0) break;
    }
  }
  console.log(`[scrapeAmazonSearch] Extracted totalResults=${totalResults} from HTML`);

  // 検索結果カードを解析
  $('[data-component-type="s-search-result"]').each((_, el) => {
    const $el = $(el);
    const asin = $el.attr("data-asin");
    if (!asin || asin.length !== 10) return;

    // 商品名
    const title =
      $el.find("h2 a span").text().trim() ||
      $el.find(".a-text-normal").first().text().trim();

    // 画像URL
    const image =
      $el.find("img.s-image").attr("src") || "";

    // 価格
    const price =
      $el.find(".a-price .a-offscreen").first().text().trim() || null;

    if (title && image) {
      items.push({
        asin,
        title,
        imageUrl: image,
        detailPageUrl: `https://www.amazon.co.jp/dp/${asin}`,
        affiliateUrl: makeAffiliateUrl(asin),
        price,
      });
    }
  });

  const sliced = items.slice(0, 10);
  // totalResultsが取れなかった場合はアイテム数をフォールバック
  if (totalResults === 0) totalResults = sliced.length;
  console.log(`[scrapeAmazonSearch] Parsed ${items.length} items, totalResults=${totalResults} from HTML (length: ${html.length})`);
  return { items: sliced, totalResults };
}

async function scrapeAmazonProduct(asin) {
  const url = `https://www.amazon.co.jp/dp/${asin}?language=ja_JP`;

  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), 8000);
  const response = await fetch(url, {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Accept-Language": "ja-JP,ja;q=0.9,en;q=0.8",
      "Accept":
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    },
    signal: ac.signal,
  }).finally(() => clearTimeout(tid));

  if (!response.ok) {
    throw new Error(`Amazon returned status ${response.status}`);
  }

  const html = await response.text();
  const cheerio = require("cheerio");
  const $ = cheerio.load(html);

  const title =
    $("#productTitle").text().trim() ||
    $("h1#title span").text().trim();

  const image =
    $("#imgBlkFront").attr("src") ||
    $("#landingImage").attr("src") ||
    $("#main-image").attr("src") ||
    "";

  const price =
    $(".a-price .a-offscreen").first().text().trim() ||
    $("#priceblock_ourprice").text().trim() ||
    null;

  return {
    asin,
    title,
    imageUrl: image,
    detailPageUrl: `https://www.amazon.co.jp/dp/${asin}`,
    affiliateUrl: makeAffiliateUrl(asin),
    price,
  };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Cloud Function: Amazon 商品キーワード検索
// PA-API → スクレイピング のフォールバック付き
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.amazonSearch = functions.https.onRequest(async (req, res) => {
  // CORS
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  res.set("X-Function-Version", "v4");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }

  const keyword = req.query.q;
  const page = parseInt(req.query.page) || 1;
  if (!keyword) {
    res.status(400).json({ error: "Missing query parameter: q" });
    return;
  }

  // 認証情報の有無をログ出力
  const hasCredentials = hasPaapiCredentials();
  console.log(`[amazonSearch] keyword="${keyword}", page=${page}, hasPaapiCredentials=${hasCredentials}`);

  // 1) PA-API が使える場合はそちらを優先
  if (hasCredentials) {
    try {
      const { partnerTag } = getCredentials();

      const payload = JSON.stringify({
        Keywords: keyword,
        Resources: [
          "ItemInfo.Title",
          "Images.Primary.Large",
          "Images.Primary.Medium",
          "Offers.Listings.Price",
          "Offers.Listings.MerchantInfo",
          "Offers.Listings.Condition",
          "Offers.Summaries.LowestPrice",
          "Offers.Summaries.HighestPrice",
        ],
        SearchIndex: "All",
        ItemCount: 10,
        ItemPage: page,
        PartnerTag: partnerTag,
        PartnerType: "Associates",
        Marketplace: "www.amazon.co.jp",
      });

      const { headers, url } = signRequest(payload, "SearchItems");

      const ac = new AbortController();
      const tid = setTimeout(() => ac.abort(), 12000);
      const response = await fetch(url, {
        method: "POST",
        headers,
        body: payload,
        signal: ac.signal,
      }).finally(() => clearTimeout(tid));

      const data = await response.json();

      if (response.ok) {
        const items = (data.SearchResult?.Items || []).map(extractItem);
        const totalResults = data.SearchResult?.TotalResultCount || items.length;
        console.log(`[amazonSearch] PA-API success: ${items.length} items, totalResults=${totalResults}, raw offers sample:`,
          JSON.stringify(data.SearchResult?.Items?.[0]?.Offers || "no-offers").substring(0, 200));

        // PA-APIで価格が取れないアイテムがある場合、並行してスクレイピングで価格補完を試行
        const itemsNeedingPrice = items.filter(i => !i.price);
        if (itemsNeedingPrice.length > 0) {
          console.log(`[amazonSearch] ${itemsNeedingPrice.length} items without price, trying scraping supplement...`);
          try {
            const scraped = await scrapeAmazonSearch(keyword);
            const priceMap = {};
            for (const si of scraped.items) {
              if (si.price) priceMap[si.asin] = si.price;
            }
            for (const item of items) {
              if (!item.price && priceMap[item.asin]) {
                item.price = priceMap[item.asin];
              }
            }
            console.log(`[amazonSearch] Price supplemented for ${Object.keys(priceMap).length} items via scraping`);
          } catch (e) {
            console.warn(`[amazonSearch] Scraping price supplement failed: ${e.message}`);
          }
        }

        res.json({ totalResults, items });
        return;
      }

      console.warn(`[amazonSearch] PA-API failed (${response.status}):`, JSON.stringify(data).substring(0, 500));
    } catch (paapiError) {
      console.warn(`[amazonSearch] PA-API error: ${paapiError.message}`);
    }
  }

  // 2) フォールバック: スクレイピング
  try {
    console.log(`[amazonSearch] Trying scraping fallback...`);
    const scraped = await scrapeAmazonSearch(keyword);
    console.log(`[amazonSearch] Scraping success: ${scraped.items.length} items, totalResults=${scraped.totalResults}`);
    res.json({ totalResults: scraped.totalResults, items: scraped.items });
  } catch (scrapeError) {
    console.error(`[amazonSearch] Scraping also failed: ${scrapeError.message}`);
    // エラーでも空を返す（UIで手動入力を促す）
    res.json({ totalResults: 0, items: [] });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Cloud Function: ASIN で商品情報取得
// PA-API → スクレイピング のフォールバック付き
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.amazonProduct = functions.https.onRequest(async (req, res) => {
  // CORS
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }

  const asin = req.query.asin;
  if (!asin) {
    res.status(400).json({ error: "Missing query parameter: asin" });
    return;
  }

  // 1) PA-API が使える場合はそちらを優先
  if (hasPaapiCredentials()) {
    try {
      const { partnerTag } = getCredentials();

      const payload = JSON.stringify({
        ItemIds: [asin],
        Resources: [
          "ItemInfo.Title",
          "Images.Primary.Large",
          "Images.Primary.Medium",
          "Offers.Listings.Price",
          "Offers.Listings.MerchantInfo",
          "Offers.Listings.Condition",
          "Offers.Summaries.LowestPrice",
          "Offers.Summaries.HighestPrice",
        ],
        PartnerTag: partnerTag,
        PartnerType: "Associates",
        Marketplace: "www.amazon.co.jp",
      });

      const { headers, url } = signRequest(payload, "GetItems");
      const response = await fetch(url, {
        method: "POST",
        headers,
        body: payload,
      });

      const data = await response.json();

      if (response.ok) {
        const items = data.ItemsResult?.Items || [];
        if (items.length > 0) {
          const result = extractItem(items[0]);
          // PA-APIで価格が取れなかった場合、スクレイピングで価格だけ補完
          if (!result.price) {
            try {
              const scraped = await scrapeAmazonProduct(asin);
              if (scraped.price) {
                result.price = scraped.price;
                console.log(`[amazonProduct] Price supplemented by scraping: ${scraped.price}`);
              }
            } catch (e) {
              console.warn(`[amazonProduct] Price scraping supplement failed: ${e.message}`);
            }
          }
          res.json(result);
          return;
        }
      }

      console.warn("PA-API failed for product, falling back to scraping");
    } catch (paapiError) {
      console.warn("PA-API error for product, falling back:", paapiError.message);
    }
  }

  // 2) フォールバック: スクレイピング
  try {
    const product = await scrapeAmazonProduct(asin);
    if (product.title) {
      res.json(product);
    } else {
      // スクレイピングでも取得できない場合、最低限の情報を返す
      res.json({
        asin,
        title: "",
        imageUrl: `https://images-na.ssl-images-amazon.com/images/P/${asin}.09.LZZZZZZZ.jpg`,
        detailPageUrl: `https://www.amazon.co.jp/dp/${asin}`,
        affiliateUrl: makeAffiliateUrl(asin),
        price: null,
      });
    }
  } catch (scrapeError) {
    console.error("Scraping also failed for product:", scrapeError.message);
    // 最低限の情報を返す
    res.json({
      asin,
      title: "",
      imageUrl: `https://images-na.ssl-images-amazon.com/images/P/${asin}.09.LZZZZZZZ.jpg`,
      detailPageUrl: `https://www.amazon.co.jp/dp/${asin}`,
      affiliateUrl: makeAffiliateUrl(asin),
      price: null,
    });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 診断エンドポイント: Amazon検索の問題を特定
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.amazonSearchDebug = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }

  // Firebase Auth トークン検証（管理者のみアクセス可能）
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  try {
    await admin.auth().verifyIdToken(authHeader.split("Bearer ")[1]);
  } catch (e) {
    res.status(403).json({ error: "Invalid or expired token" });
    return;
  }

  const result = {
    credentials: {
      hasAccessKey: !!process.env.AMAZON_ACCESS_KEY,
      hasSecretKey: !!process.env.AMAZON_SECRET_KEY,
      hasPartnerTag: !!process.env.AMAZON_PARTNER_TAG,
    },
    paapiTest: null,
    scrapeTest: null,
  };

  const keyword = req.query.q || "バレーボール";

  // PA-API テスト
  if (hasPaapiCredentials()) {
    try {
      const { partnerTag } = getCredentials();
      const payload = JSON.stringify({
        Keywords: keyword,
        Resources: [
          "ItemInfo.Title",
          "Offers.Listings.Price",
          "Offers.Summaries.LowestPrice",
          "Offers.Summaries.HighestPrice",
        ],
        Condition: "New",
        SearchIndex: "All",
        ItemCount: 1,
        PartnerTag: partnerTag,
        PartnerType: "Associates",
        Marketplace: "www.amazon.co.jp",
      });

      const { headers, url } = signRequest(payload, "SearchItems");
      const ac = new AbortController();
      const tid = setTimeout(() => ac.abort(), 12000);
      const response = await fetch(url, {
        method: "POST", headers, body: payload, signal: ac.signal,
      }).finally(() => clearTimeout(tid));

      const data = await response.json();
      const firstItem = data.SearchResult?.Items?.[0];
      result.paapiTest = {
        status: response.status,
        ok: response.ok,
        itemCount: data.SearchResult?.Items?.length || 0,
        error: data.Errors ? data.Errors.map(e => e.Message).join("; ") : null,
        hasOffers: !!firstItem?.Offers,
        offersData: firstItem?.Offers ? JSON.stringify(firstItem.Offers).substring(0, 500) : "no offers returned",
        rawSnippet: JSON.stringify(data).substring(0, 500),
      };
    } catch (e) {
      result.paapiTest = { error: e.message };
    }
  } else {
    result.paapiTest = { error: "Credentials not configured" };
  }

  // スクレイピング テスト
  try {
    const ac = new AbortController();
    const tid = setTimeout(() => ac.abort(), 10000);
    const scrapeUrl = `https://www.amazon.co.jp/s?k=${encodeURIComponent(keyword)}&language=ja_JP`;
    const response = await fetch(scrapeUrl, {
      headers: {
        "User-Agent": randomUserAgent(),
        "Accept-Language": "ja-JP,ja;q=0.9",
        "Accept": "text/html",
      },
      redirect: "follow",
      signal: ac.signal,
    }).finally(() => clearTimeout(tid));

    const html = await response.text();
    const hasCaptcha = html.includes("captcha") || html.includes("robot");
    const cheerio = require("cheerio");
    const $ = cheerio.load(html);
    const resultCount = $('[data-component-type="s-search-result"]').length;

    result.scrapeTest = {
      status: response.status,
      htmlLength: html.length,
      hasCaptcha,
      resultCount,
      titleTag: $("title").text().trim().substring(0, 100),
    };
  } catch (e) {
    result.scrapeTest = { error: e.message };
  }

  res.json(result);
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ガジェット → Google Sheets 同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function doSyncGadgetsToSheet() {
  const usersSnap = await admin.firestore().collection("users").get();
  const allGadgets = [];

  for (const userDoc of usersSnap.docs) {
    const userData = userDoc.data();
    const nickname = userData.nickname || "不明";
    const searchId = userData.searchId || userDoc.id;
    const gadgetsSnap = await userDoc.ref.collection("gadgets")
      .orderBy("createdAt", "desc").get();

    for (const gDoc of gadgetsSnap.docs) {
      const g = gDoc.data();
      allGadgets.push([
        gDoc.id,
        searchId,
        nickname,
        g.name || "",
        g.category || "カテゴリなし",
        g.amazonUrl || "",
        g.amazonAffiliateUrl || "",
        g.rakutenAffiliateUrl || "",
        g.imageUrl || "",
        g.memo || "",
        g.createdAt ? g.createdAt.toDate().toISOString().split("T")[0] : "",
      ]);
    }
  }

  const sheetName = "ガジェット一覧";
  const values = [
    ["ガジェットID", "ユーザーID", "ユーザー", "商品名", "カテゴリ", "Amazon URL", "Amazon Affiliate URL", "楽天 Affiliate URL", "画像URL", "メモ", "登録日"],
    ...allGadgets,
  ];

  try {
    await sheetsUpdate(GADGET_SHEET_ID, `${sheetName}!A1`, values);
  } catch (e) {
    await sheetsAddSheet(GADGET_SHEET_ID, sheetName);
    await sheetsUpdate(GADGET_SHEET_ID, `${sheetName}!A1`, values);
  }
  const nextRow = values.length + 1;
  await sheetsClear(GADGET_SHEET_ID, `${sheetName}!A${nextRow}:K10000`);

  return allGadgets.length;
}

exports.syncGadgetsToSheet = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const count = await doSyncGadgetsToSheet();
    res.json({ success: true, count });
  } catch (e) {
    console.error("Gadget sync error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 会場 → Google Sheets 同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function doSyncVenuesToSheet() {
  const venuesSnap = await admin.firestore().collection("venues")
    .orderBy("name").get();

  const venueRows = venuesSnap.docs.map((doc) => {
    const v = doc.data();
    const ts = v.timeSlots || {};
    const am = ts.am || {};
    const pm = ts.pm || {};
    const night = ts.night || {};
    return [
      doc.id,
      v.name || "",
      v.address || "",
      v.phone || "",
      v.station || "",
      v.courts || 0,
      v.parking || 0,
      v.hasToilet ? "あり" : "なし",
      v.hasChangeRoom ? "あり" : "なし",
      v.hasShower ? "あり" : "なし",
      v.hasGallery ? "あり" : "なし",
      v.hasAC ? "あり" : "なし",
      v.eatArea || "",
      v.openTime || "",
      v.closeTime || "",
      v.fee || "",
      (v.equipments || []).map((eq) => `${eq.name}(${eq.qty}個${eq.fee > 0 ? "/¥" + eq.fee : "/無料"})`).join(", "),
      v.floorType || "",
      v.poleType || "",
      v.poleAdjustable ? "可" : "不可",
      v.notes || "",
      am.start || "", am.end || "", am.fee || "",
      pm.start || "", pm.end || "", pm.fee || "",
      night.start || "", night.end || "", night.fee || "",
      v.rating || 0,
      v.reviewCount || 0,
      v.createdAt ? v.createdAt.toDate().toISOString().split("T")[0] : "",
    ];
  });

  const sheetName = "会場一覧";
  const values = [
    ["会場ID", "会場名", "住所", "電話", "最寄り駅", "コート数", "駐車場", "トイレ",
     "更衣室", "シャワー", "観覧席", "空調", "飲食エリア",
     "開始時間", "終了時間", "料金", "貸出備品",
     "床タイプ", "ポールタイプ", "ポール高さ調整", "備考",
     "午前開始", "午前終了", "午前料金", "午後開始", "午後終了", "午後料金",
     "夜間開始", "夜間終了", "夜間料金",
     "評価", "レビュー数", "登録日"],
    ...venueRows,
  ];

  try {
    await sheetsUpdate(VENUE_SHEET_ID, `${sheetName}!A1`, values);
  } catch (e) {
    await sheetsAddSheet(VENUE_SHEET_ID, sheetName);
    await sheetsUpdate(VENUE_SHEET_ID, `${sheetName}!A1`, values);
  }
  const nextRow = values.length + 1;
  await sheetsClear(VENUE_SHEET_ID, `${sheetName}!A${nextRow}:AF10000`);

  return venueRows.length;
}

exports.syncVenuesToSheet = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const count = await doSyncVenuesToSheet();
    res.json({ success: true, count });
  } catch (e) {
    console.error("Venue sync error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 会場データ全クリア（Firestore + Sheets）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.clearVenues = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  // Firebase Auth トークン検証（破壊的操作のため認証必須）
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  try {
    await admin.auth().verifyIdToken(authHeader.split("Bearer ")[1]);
  } catch (e) {
    res.status(403).json({ error: "Invalid or expired token" });
    return;
  }

  try {
    const db = admin.firestore();

    // 1. Firestore の venues コレクションを全削除
    const venuesSnap = await db.collection("venues").get();
    const batch = db.batch();
    venuesSnap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    const deletedCount = venuesSnap.size;

    // 2. Google Sheets の会場一覧シートをヘッダーだけ残してクリア
    const sheetName = "会場一覧";
    await sheetsClear(VENUE_SHEET_ID, `${sheetName}!A2:AF10000`);

    console.log(`Cleared ${deletedCount} venues from Firestore and Sheets`);
    res.json({ success: true, deletedFromFirestore: deletedCount });
  } catch (e) {
    console.error("Clear venues error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 全国体育館 初期データ一括登録（公式サイトから取得済み）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.seedVenues = functions.runWith({ timeoutSeconds: 540 }).https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const db = admin.firestore();

    // 既存の会場名セットを取得（重複防止）
    const existingSnap = await db.collection("venues").get();
    const existingNames = new Set(existingSnap.docs.map((d) => d.data().name));

    const venues = [
      // ── 北海道 ──
      { name: "西区体育館", address: "北海道札幌市西区発寒5条8丁目9-1" },
      { name: "札幌市月寒体育館", address: "北海道札幌市豊平区月寒東1条8丁目1-1" },
      { name: "札幌市美香保体育館", address: "北海道札幌市東区北22条東5丁目1-1" },
      { name: "旭川市総合体育館", address: "北海道旭川市花咲町5丁目4040-19" },
      { name: "東区体育館", address: "北海道札幌市東区北27条東14丁目3-1" },
      { name: "恵庭市総合体育館", address: "北海道恵庭市黄金中央5丁目199-2" },
      { name: "苫小牧市総合体育館", address: "北海道苫小牧市末広町3丁目2-16" },
      { name: "豊平区体育館", address: "北海道札幌市豊平区月寒東2条20丁目4-15" },
      { name: "北区体育館", address: "北海道札幌市北区新琴似八条2-1-25" },
      { name: "厚別区体育館", address: "北海道札幌市厚別区厚別中央2条5丁目1-20" },
      { name: "手稲区体育館", address: "北海道札幌市手稲区曙2条1丁目2-46" },
      { name: "南区体育館", address: "北海道札幌市南区川沿4条2丁目" },
      { name: "千歳市スポーツセンター", address: "北海道千歳市真町176-2" },
      { name: "音更町総合体育館", address: "北海道河東郡音更町雄飛が丘3" },
      { name: "道立野幌総合運動公園総合体育館", address: "北海道江別市西野幌481" },
      // ── 宮城県 ──
      { name: "宮城野体育館", address: "宮城県仙台市宮城野区新田東4丁目1-1" },
      { name: "仙台市泉総合運動場体育館", address: "宮城県仙台市泉区野村字新桂島前60" },
      { name: "カメイアリーナ仙台", address: "宮城県仙台市太白区富沢1丁目4-1" },
      { name: "多賀城市総合体育館", address: "宮城県多賀城市下馬5丁目9-3" },
      { name: "大崎市古川総合体育館", address: "宮城県大崎市古川旭4丁目5-2" },
      { name: "利府町総合体育館", address: "宮城県宮城郡利府町青山1丁目57-2" },
      { name: "セキスイハイムスーパーアリーナ", address: "宮城県宮城郡利府町菅谷字舘40-1" },
      { name: "塩釜ガス体育館", address: "宮城県塩竈市今宮町9-1" },
      { name: "仙台市若林体育館", address: "宮城県仙台市若林区卸町東2丁目8-10" },
      { name: "石巻市総合体育館", address: "宮城県石巻市泉町3丁目1-63" },
      // ── 埼玉県 ──
      { name: "サイデン化学アリーナ", address: "埼玉県さいたま市桜区道場4丁目3-1" },
      { name: "深谷ビッグタートル", address: "埼玉県深谷市上野台2568" },
      { name: "上尾市市民体育館", address: "埼玉県上尾市向山4丁目3-10" },
      { name: "川口市立戸塚スポーツセンター", address: "埼玉県川口市戸塚南3-22-1" },
      { name: "行田グリーンアリーナ", address: "埼玉県行田市和田1242" },
      { name: "埼玉県立武道館", address: "埼玉県上尾市日の出4丁目1877" },
      { name: "熊谷市民体育館", address: "埼玉県熊谷市桜木町2丁目33-5" },
      { name: "戸田市スポーツセンター", address: "埼玉県戸田市新曽1286" },
      { name: "草加市スポーツ健康都市記念体育館", address: "埼玉県草加市瀬崎6-31-1" },
      { name: "所沢市民体育館", address: "埼玉県所沢市並木5丁目3" },
      { name: "川越運動公園総合体育館", address: "埼玉県川越市下老袋388-1" },
      { name: "越谷市立総合体育館", address: "埼玉県越谷市増林2丁目33" },
      { name: "浦和駒場体育館", address: "埼玉県さいたま市浦和区駒場2-5-6" },
      // ── 千葉県 ──
      { name: "千葉ポートアリーナ", address: "千葉県千葉市中央区問屋町1-20" },
      { name: "柏市中央体育館", address: "千葉県柏市柏下73" },
      { name: "佐倉市民体育館", address: "千葉県佐倉市宮小路町3" },
      { name: "八千代市市民体育館", address: "千葉県八千代市萱田1220" },
      { name: "千葉県総合スポーツセンター", address: "千葉県千葉市稲毛区天台町323" },
      { name: "バルドラール浦安アリーナ", address: "千葉県浦安市舞浜2-27" },
      { name: "木更津市民体育館", address: "千葉県木更津市貝渕2-13-40" },
      { name: "船橋市運動公園体育館", address: "千葉県船橋市夏見台6丁目4-1" },
      { name: "福太郎アリーナ", address: "千葉県鎌ケ谷市初富860-3" },
      { name: "成田市中台運動公園体育館", address: "千葉県成田市中台5丁目2番地" },
      // ── 東京都 ──
      { name: "東京体育館", address: "東京都渋谷区千駄ヶ谷1丁目17-1" },
      { name: "代々木第一体育館", address: "東京都渋谷区神南2丁目1-1" },
      { name: "足立区総合スポーツセンター体育館", address: "東京都足立区東保木間2丁目27-1" },
      { name: "墨田区総合体育館", address: "東京都墨田区錦糸4丁目15-1" },
      { name: "大田区総合体育館", address: "東京都大田区東蒲田1-11-1" },
      { name: "多摩市立総合体育館", address: "東京都多摩市東寺方588-1" },
      { name: "町田市立総合体育館", address: "東京都町田市南成瀬5丁目12" },
      { name: "江戸川区スポーツセンター", address: "東京都江戸川区西葛西4丁目2-20" },
      { name: "葛飾区奥戸総合スポーツセンター体育館", address: "東京都葛飾区奥戸7丁目17-1" },
      { name: "中央区立総合スポーツセンター", address: "東京都中央区日本橋浜町2丁目59-1" },
      { name: "新宿コズミックスポーツセンター", address: "東京都新宿区大久保3丁目1-2" },
      { name: "荻窪体育館", address: "東京都杉並区荻窪3丁目47-2" },
      { name: "八王子市富士森体育館", address: "東京都八王子市台町2丁目3-7" },
      { name: "池袋スポーツセンター", address: "東京都豊島区上池袋2丁目5-1" },
      { name: "千代田区立スポーツセンター", address: "東京都千代田区内神田2丁目1-8" },
      { name: "駒沢オリンピック公園総合運動場体育館", address: "東京都世田谷区駒沢公園1-1" },
      { name: "武蔵野市立武蔵野総合体育館", address: "東京都武蔵野市吉祥寺北町5丁目11-20" },
      { name: "文京スポーツセンター体育館", address: "東京都文京区大塚3-29-2" },
      { name: "港区スポーツセンター", address: "東京都港区芝浦1-16-1" },
      { name: "品川区総合体育館", address: "東京都品川区東五反田2-11-2" },
      { name: "世田谷総合運動場体育館", address: "東京都世田谷区大蔵4丁目6-1" },
      { name: "渋谷区スポーツセンター体育館", address: "東京都渋谷区西原1-40-18" },
      { name: "中野区立総合体育館", address: "東京都中野区新井三丁目37番78号" },
      { name: "エスフォルタアリーナ八王子", address: "東京都八王子市狭間町1453-1" },
      { name: "江東区スポーツ会館", address: "東京都江東区北砂1丁目2-9" },
      { name: "板橋区立上板橋体育館", address: "東京都板橋区桜川1丁目3-1" },
      { name: "練馬区立総合体育館", address: "東京都練馬区谷原1-7-5" },
      { name: "江東区東砂スポーツセンター", address: "東京都江東区東砂4丁目24-1" },
      { name: "江戸川区総合体育館", address: "東京都江戸川区松本1丁目35-1" },
      { name: "北区滝野川体育館", address: "東京都北区西ケ原2丁目1-6" },
      { name: "目黒区民センター体育館", address: "東京都目黒区目黒2丁目4-36" },
      { name: "調布市総合体育館", address: "東京都調布市深大寺北町2丁目1-65" },
      { name: "小平市民総合体育館", address: "東京都小平市津田町1丁目1-1" },
      { name: "府中市郷土の森総合体育館", address: "東京都府中市矢崎町5丁目5" },
      { name: "小金井市総合体育館", address: "東京都小金井市関野町1丁目13-1" },
      { name: "稲城市中央公園総合体育館", address: "東京都稲城市長峰1丁目1" },
      { name: "昭島市総合スポーツセンター", address: "東京都昭島市東町5丁目13-1" },
      { name: "狛江市民総合体育館", address: "東京都狛江市和泉本町3丁目25-1" },
      { name: "くにたち市民総合体育館", address: "東京都国立市富士見台2-48-1" },
      // ── 神奈川県 ──
      { name: "小田原アリーナ", address: "神奈川県小田原市中曽根263" },
      { name: "茅ヶ崎市総合体育館", address: "神奈川県茅ヶ崎市茅ヶ崎1丁目9-63" },
      { name: "藤沢市秩父宮記念体育館", address: "神奈川県藤沢市鵠沼東8-2" },
      { name: "カルッツかわさき", address: "神奈川県川崎市川崎区富士見1丁目1-4" },
      { name: "横浜市港北スポーツセンター", address: "神奈川県横浜市港北区大豆戸町518-1" },
      { name: "寒川総合体育館", address: "神奈川県高座郡寒川町宮山275" },
      { name: "秦野市総合体育館", address: "神奈川県秦野市平沢101-1" },
      { name: "相模原ギオンアリーナ", address: "神奈川県相模原市南区麻溝台2284-1" },
      { name: "横浜武道館", address: "神奈川県横浜市中区翁町2-9-10" },
      { name: "平塚総合体育館", address: "神奈川県平塚市大原1-1" },
      { name: "綾瀬市民スポーツセンター体育館", address: "神奈川県綾瀬市深谷上3丁目6-1" },
      { name: "海老名運動公園総合体育館", address: "神奈川県海老名市社家4032-1" },
      { name: "横浜BUNTAI", address: "神奈川県横浜市中区不老町2丁目7番1" },
      { name: "三浦市総合体育館潮風アリーナ", address: "神奈川県三浦市初声町入江169" },
      { name: "大和市大和スポーツセンター", address: "神奈川県大和市上草柳1-1-1" },
      // ── 愛知県 ──
      { name: "ドルフィンズアリーナ", address: "愛知県名古屋市中区二の丸1-1" },
      { name: "パークアリーナ小牧", address: "愛知県小牧市間々原新田737" },
      { name: "春日井市総合体育館", address: "愛知県春日井市鷹来町4196-3" },
      { name: "日本ガイシスポーツプラザ", address: "愛知県名古屋市南区東又兵ヱ町5丁目1番地の16" },
      { name: "刈谷市体育館", address: "愛知県刈谷市逢妻町4丁目32" },
      { name: "ウィングアリーナ刈谷", address: "愛知県刈谷市築地町荒田1番地" },
      { name: "岡崎市中央総合公園総合体育館", address: "愛知県岡崎市高隆寺町峠1" },
      { name: "スカイホール豊田", address: "愛知県豊田市八幡町1丁目20" },
      { name: "安城市体育館", address: "愛知県安城市新田町新定山41-8" },
      { name: "名古屋市千種スポーツセンター", address: "愛知県名古屋市千種区星が丘山手121" },
      { name: "名古屋市東スポーツセンター", address: "愛知県名古屋市東区大幸南1丁目1-10" },
      { name: "名古屋市天白スポーツセンター", address: "愛知県名古屋市天白区植田3丁目1502" },
      { name: "名古屋市守山スポーツセンター", address: "愛知県名古屋市守山区竜泉寺2丁目112" },
      { name: "東海市民体育館", address: "愛知県東海市高横須賀町桝形1-1" },
      { name: "KTXアリーナ", address: "愛知県江南市高屋町清水118番地" },
      // ── 京都府 ──
      { name: "ハンナリーズアリーナ", address: "京都府京都市右京区西京極新明町1" },
      { name: "島津アリーナ京都", address: "京都府京都市北区大将軍西鷹司町" },
      { name: "田辺中央体育館", address: "京都府京田辺市田辺丸山19" },
      { name: "向日市民体育館", address: "京都府向日市森本町小柳23-1" },
      { name: "久御山町総合体育館", address: "京都府久世郡久御山町市田新珠城313" },
      { name: "亀岡運動公園体育館", address: "京都府亀岡市曽我部町穴太土渕33-1" },
      { name: "長岡京市西山公園体育館", address: "京都府長岡京市長法寺谷山1" },
      { name: "福知山市民体育館", address: "京都府福知山市和久市町254" },
      { name: "城陽市民体育館", address: "京都府城陽市寺田奥山1" },
      { name: "木津川市中央体育館", address: "京都府木津川市木津石塚147" },
      // ── 大阪府 ──
      { name: "丸善インテックアリーナ大阪", address: "大阪府大阪市港区田中3丁目1-40" },
      { name: "東和薬品RACTABドーム", address: "大阪府門真市三ツ島3丁目7-16" },
      { name: "岸和田市総合体育館", address: "大阪府岸和田市西之内町45-1" },
      { name: "大浜体育館", address: "大阪府堺市堺区大浜北町5丁目7-1" },
      { name: "総合体育館東大阪アリーナ", address: "大阪府東大阪市中小阪4丁目7-60" },
      { name: "八尾市立総合体育館ウイング", address: "大阪府八尾市青山町3丁目5-24" },
      { name: "枚方市立総合スポーツセンター総合体育館", address: "大阪府枚方市中宮大池4丁目10-1" },
      { name: "守口市民体育館", address: "大阪府守口市河原町9-2" },
      { name: "茨木市立市民体育館", address: "大阪府茨木市小川町2-1" },
      { name: "豊中市立豊島体育館", address: "大阪府豊中市服部西町4丁目12-1" },
      { name: "貝塚市立総合体育館", address: "大阪府貝塚市畠中1丁目13-1" },
      { name: "高槻市総合スポーツセンター", address: "大阪府高槻市芝生町4丁目1-1" },
      { name: "大阪狭山市立総合体育館", address: "大阪府大阪狭山市池之原4丁目248" },
      { name: "池田市立総合スポーツセンター", address: "大阪府池田市荘園2-7-30" },
      { name: "吹田市立片山市民体育館", address: "大阪府吹田市出口町31-2" },
      // ── 兵庫県 ──
      { name: "加古川市立総合体育館", address: "兵庫県加古川市西神吉町鼎1010" },
      { name: "ベイコム総合体育館", address: "兵庫県尼崎市西長洲町1丁目4-1" },
      { name: "神戸市立中央体育館", address: "兵庫県神戸市中央区楠町4丁目1-1" },
      { name: "姫路市立総合スポーツ会館", address: "兵庫県姫路市中地453" },
      { name: "宝塚市立スポーツセンター", address: "兵庫県宝塚市小浜1丁目1-11" },
      { name: "伊丹スポーツセンター", address: "兵庫県伊丹市鴻池1丁目1番1号" },
      { name: "西宮市立中央体育館", address: "兵庫県西宮市河原町1-16" },
      { name: "小野市総合体育館アルゴ", address: "兵庫県小野市王子町917-1" },
      { name: "グリーンアリーナ神戸", address: "兵庫県神戸市須磨区緑台" },
      { name: "ヴィクトリーナ・ウインク体育館", address: "兵庫県姫路市西延末90" },
      // ── 福岡県 ──
      { name: "福岡市民体育館", address: "福岡県福岡市博多区東公園8-2" },
      { name: "福岡市立博多体育館", address: "福岡県福岡市博多区山王1丁目9-5" },
      { name: "北九州市立総合体育館", address: "福岡県北九州市八幡東区八王寺町4-1" },
      { name: "照葉積水ハウスアリーナ", address: "福岡県福岡市東区香椎照葉六丁目1番1号" },
      { name: "久留米総合スポーツセンター体育館", address: "福岡県久留米市東櫛原町173" },
      { name: "福岡市立城南体育館", address: "福岡県福岡市城南区別府6丁目14-22" },
      { name: "福岡市立西体育館", address: "福岡県福岡市西区拾六町1丁目13-35" },
      { name: "福岡市立南体育館", address: "福岡県福岡市南区塩原2丁目8-1" },
      { name: "宗像市市民体育館", address: "福岡県宗像市稲元5丁目2-1" },
      { name: "大野城市総合体育館", address: "福岡県大野城市大字乙金618-12" },
      { name: "春日市総合スポーツセンター", address: "福岡県春日市大谷6丁目28" },
      { name: "福岡市中央体育館", address: "福岡県福岡市中央区赤坂2丁目5-5" },
    ];

    let imported = 0;
    for (const v of venues) {
      if (existingNames.has(v.name)) continue;
      await db.collection("venues").add({
        ...v,
        courts: 0,
        parking: 0,
        hasToilet: false,
        hasChangeRoom: false,
        hasAC: false,
        rating: 0,
        reviewCount: 0,
        registeredBy: "seed",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      imported++;
    }

    // Google Sheets にも同期
    try { await doSyncVenuesToSheet(); } catch (e) { console.error("Sheet sync error:", e); }

    res.json({ success: true, imported, skipped: venues.length - imported, total: venues.length });
  } catch (e) {
    console.error("Seed venues error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// お知らせ初期データ登録（1回だけ実行）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.seedNotices = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const db = admin.firestore();
    const existing = await db.collection("notices").limit(1).get();
    if (!existing.empty) {
      res.json({ message: "お知らせは既に登録済みです", count: 0 });
      return;
    }

    const notices = [
      {
        type: "release",
        title: "Sofvo 正式リリースのお知らせ",
        body: "ソフトバレーボール マッチングアプリ「Sofvo」をご利用いただきありがとうございます。大会検索・メンバー募集・チャットなどの機能をお楽しみください。",
        createdAt: admin.firestore.Timestamp.fromDate(new Date("2026-02-14T00:00:00+09:00")),
      },
      {
        type: "update",
        title: "バージョン 1.1 アップデート",
        body: "大会検索のフィルター機能が強化されました。種別・エリア・日付での絞り込みが可能です。",
        createdAt: admin.firestore.Timestamp.fromDate(new Date("2026-02-10T00:00:00+09:00")),
      },
    ];

    const batch = db.batch();
    for (const notice of notices) {
      batch.set(db.collection("notices").doc(), notice);
    }
    await batch.commit();

    res.json({ success: true, count: notices.length });
  } catch (e) {
    console.error("Seed notices error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Firestore トリガー: ガジェット変更時に自動同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.onGadgetWrite = functions.firestore
  .document("users/{userId}/gadgets/{gadgetId}")
  .onWrite(async (change) => {
    // ユーザー向けフィールドに変更がなければスキップ（インポート起因の無限ループ防止）
    if (change.before.exists && change.after.exists) {
      const before = change.before.data();
      const after = change.after.data();
      const fields = ["name", "category", "amazonUrl", "amazonAffiliateUrl", "rakutenAffiliateUrl", "imageUrl", "memo"];
      const changed = fields.some((f) => (before[f] || "") !== (after[f] || ""));
      if (!changed) return;
    }
    try {
      const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
      const syncUrl = `https://us-central1-${projectId}.cloudfunctions.net/syncGadgetsToSheet`;
      const ac = new AbortController();
      const tid = setTimeout(() => ac.abort(), 30000);
      await fetch(syncUrl, { method: "POST", signal: ac.signal }).finally(() => clearTimeout(tid));
    } catch (e) {
      console.warn("Auto gadget sync failed (non-critical):", e.message);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Firestore トリガー: ユーザープロフィール変更時にガジェットシート再同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.onUserWrite = functions.firestore
  .document("users/{userId}")
  .onWrite(async (change, context) => {
    if (!change.before.exists || !change.after.exists) return;
    const before = change.before.data();
    const after = change.after.data();
    const userId = context.params.userId;

    const nicknameChanged = (before.nickname || "") !== (after.nickname || "");
    const avatarChanged = (before.avatarUrl || "") !== (after.avatarUrl || "");

    // searchId または nickname が変わった場合のみシート再同期
    if (nicknameChanged || (before.searchId || "") !== (after.searchId || "")) {
      try {
        const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
        const syncUrl = `https://us-central1-${projectId}.cloudfunctions.net/syncGadgetsToSheet`;
        const ac = new AbortController();
        const tid = setTimeout(() => ac.abort(), 30000);
        await fetch(syncUrl, { method: "POST", signal: ac.signal }).finally(() => clearTimeout(tid));
      } catch (e) {
        console.warn("Auto user-profile gadget sync failed (non-critical):", e.message);
      }
    }

    // ニックネームまたはアバターが変わった場合、非正規化データを同期
    if (!nicknameChanged && !avatarChanged) return;

    const db = admin.firestore();
    const newNickname = after.nickname || "";
    const newAvatar = after.avatarUrl || "";

    try {
      // 1. フォロワーの following サブコレクション内の自分のドキュメントを更新
      const followersSnap = await db.collection("users").doc(userId).collection("followers").get();
      const batch1 = db.batch();
      for (const doc of followersSnap.docs) {
        batch1.update(db.collection("users").doc(doc.id).collection("following").doc(userId), {
          nickname: newNickname, avatarUrl: newAvatar,
        });
      }
      if (followersSnap.docs.length > 0) await batch1.commit();

      // 2. フォロー先の followers サブコレクション内の自分のドキュメントを更新
      const followingSnap = await db.collection("users").doc(userId).collection("following").get();
      const batch2 = db.batch();
      for (const doc of followingSnap.docs) {
        batch2.update(db.collection("users").doc(doc.id).collection("followers").doc(userId), {
          nickname: newNickname, avatarUrl: newAvatar,
        });
      }
      if (followingSnap.docs.length > 0) await batch2.commit();

      // 3. 自分の投稿の userNickname / userAvatarUrl を更新
      const postsSnap = await db.collection("posts").where("userId", "==", userId).get();
      if (postsSnap.docs.length > 0) {
        const batch3 = db.batch();
        for (const doc of postsSnap.docs) {
          batch3.update(doc.ref, { userNickname: newNickname, userAvatarUrl: newAvatar });
        }
        await batch3.commit();
      }

      // 4. 主催大会の organizerName を更新
      if (nicknameChanged) {
        const tournsSnap = await db.collection("tournaments").where("organizerId", "==", userId).get();
        if (tournsSnap.docs.length > 0) {
          const batch4 = db.batch();
          for (const doc of tournsSnap.docs) {
            batch4.update(doc.ref, { organizerName: newNickname });
          }
          await batch4.commit();
        }
      }

      console.log(`[UserSync] Synced nickname/avatar for user ${userId}`);
    } catch (e) {
      console.warn(`[UserSync] Failed to sync denormalized data for ${userId}:`, e.message);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Firestore トリガー: 会場変更時に自動同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.onVenueWrite = functions.firestore
  .document("venues/{venueId}")
  .onWrite(async (change) => {
    // ユーザー向けフィールドに変更がなければスキップ（インポート起因の無限ループ防止）
    if (change.before.exists && change.after.exists) {
      const before = change.before.data();
      const after = change.after.data();
      const strFields = ["name", "address", "phone", "station", "eatArea", "openTime", "closeTime", "fee", "floorType", "poleType", "notes"];
      const numFields = ["courts", "parking"];
      const boolFields = ["hasToilet", "hasChangeRoom", "hasShower", "hasGallery", "hasAC", "poleAdjustable"];
      const strChanged = strFields.some((f) => (before[f] || "") !== (after[f] || ""));
      const numChanged = numFields.some((f) => (before[f] || 0) !== (after[f] || 0));
      const boolChanged = boolFields.some((f) => !!before[f] !== !!after[f]);
      const eqChanged = JSON.stringify(before.equipments || []) !== JSON.stringify(after.equipments || []);
      const tsChanged = JSON.stringify(before.timeSlots || {}) !== JSON.stringify(after.timeSlots || {});
      if (!strChanged && !numChanged && !boolChanged && !eqChanged && !tsChanged) return;
    }
    try {
      const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
      const syncUrl = `https://us-central1-${projectId}.cloudfunctions.net/syncVenuesToSheet`;
      const ac = new AbortController();
      const tid = setTimeout(() => ac.abort(), 30000);
      await fetch(syncUrl, { method: "POST", signal: ac.signal }).finally(() => clearTimeout(tid));
    } catch (e) {
      console.warn("Auto venue sync failed (non-critical):", e.message);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Google Sheets → Firestore インポート (会場) 共通ロジック
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// 比較用: Firestore のデータとシートのデータが同じかチェック
function isVenueDataEqual(existing, sheetData) {
  const fields = ["name", "address", "phone", "station", "eatArea", "openTime", "closeTime", "fee", "floorType", "poleType", "notes"];
  for (const f of fields) {
    if ((existing[f] || "") !== (sheetData[f] || "")) return false;
  }
  const numFields = ["courts", "parking"];
  for (const f of numFields) {
    if ((existing[f] || 0) !== (sheetData[f] || 0)) return false;
  }
  const boolFields = ["hasToilet", "hasChangeRoom", "hasShower", "hasGallery", "hasAC", "poleAdjustable"];
  for (const f of boolFields) {
    if (!!existing[f] !== !!sheetData[f]) return false;
  }
  if (JSON.stringify(existing.equipments || []) !== JSON.stringify(sheetData.equipments || [])) return false;
  if (JSON.stringify(existing.timeSlots || {}) !== JSON.stringify(sheetData.timeSlots || {})) return false;
  return true;
}

async function doImportVenues() {
  const rows = await sheetsRead(VENUE_SHEET_ID, "会場一覧!A:AF");
  if (rows.length < 2) return { imported: 0, updated: 0, skipped: 0, total: 0 };

  const db = admin.firestore();
  const dataRows = rows.slice(1);
  let imported = 0;
  let updated = 0;
  let skipped = 0;

  for (const row of dataRows) {
    const venueId = (row[0] || "").trim();
    const name = (row[1] || "").trim();
    if (!name) { skipped++; continue; }

    const venueData = {
      name,
      address: row[2] || "",
      phone: row[3] || "",
      station: row[4] || "",
      courts: parseInt(row[5]) || 0,
      parking: parseInt(row[6]) || 0,
      hasToilet: (row[7] || "").trim() === "あり",
      hasChangeRoom: (row[8] || "").trim() === "あり",
      hasShower: (row[9] || "").trim() === "あり",
      hasGallery: (row[10] || "").trim() === "あり",
      hasAC: (row[11] || "").trim() === "あり",
      eatArea: row[12] || "",
      openTime: row[13] || "",
      closeTime: row[14] || "",
      fee: row[15] || "",
    };

    if (row[16]) {
      const eqParts = row[16].split(",").map((s) => s.trim()).filter(Boolean);
      venueData.equipments = eqParts.map((part) => {
        const m = part.match(/^(.+?)\((\d+)個(?:\/¥(\d+)|\/無料)?\)$/);
        if (m) return { name: m[1], qty: parseInt(m[2]) || 1, fee: parseInt(m[3]) || 0 };
        return { name: part, qty: 1, fee: 0 };
      });
    }

    // 新規カラム（床タイプ、ポール、備考、時間帯別料金）
    venueData.floorType = row[17] || "";
    venueData.poleType = row[18] || "";
    venueData.poleAdjustable = (row[19] || "").trim() === "可";
    venueData.notes = row[20] || "";
    venueData.timeSlots = {
      am: { start: row[21] || "", end: row[22] || "", fee: row[23] || "" },
      pm: { start: row[24] || "", end: row[25] || "", fee: row[26] || "" },
      night: { start: row[27] || "", end: row[28] || "", fee: row[29] || "" },
    };

    if (venueId) {
      const existing = await db.collection("venues").doc(venueId).get();
      if (existing.exists) {
        // データが変わっていなければスキップ（無限ループ防止）
        if (isVenueDataEqual(existing.data(), venueData)) { skipped++; continue; }
        venueData.updatedAt = admin.firestore.FieldValue.serverTimestamp();

        await db.collection("venues").doc(venueId).update(venueData);
        updated++;
      } else {
        venueData.createdAt = admin.firestore.FieldValue.serverTimestamp();
        venueData.updatedAt = admin.firestore.FieldValue.serverTimestamp();
        venueData.registeredBy = "sheet_import";

        venueData.rating = 0;
        venueData.reviewCount = 0;
        await db.collection("venues").doc(venueId).set(venueData);
        imported++;
      }
    } else {
      venueData.createdAt = admin.firestore.FieldValue.serverTimestamp();
      venueData.updatedAt = admin.firestore.FieldValue.serverTimestamp();
      venueData.registeredBy = "sheet_import";
      venueData.rating = 0;
      venueData.reviewCount = 0;
      await db.collection("venues").add(venueData);
      imported++;
    }
  }

  return { imported, updated, skipped, total: dataRows.length };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Google Sheets → Firestore インポート (ガジェット) 共通ロジック
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// 比較用: Firestore のデータとシートのデータが同じかチェック
function isGadgetDataEqual(existing, sheetData) {
  const fields = ["name", "category", "amazonUrl", "amazonAffiliateUrl", "rakutenAffiliateUrl", "imageUrl", "memo"];
  for (const f of fields) {
    if ((existing[f] || "") !== (sheetData[f] || "")) return false;
  }
  return true;
}

async function doImportGadgets() {
  const rows = await sheetsRead(GADGET_SHEET_ID, "ガジェット一覧!A:K");
  if (rows.length < 2) return { imported: 0, updated: 0, skipped: 0, total: 0 };

  const db = admin.firestore();
  const dataRows = rows.slice(1);
  let imported = 0;
  let updated = 0;
  let skipped = 0;

  // searchId → Firebase UID のマッピングを事前に構築
  const usersSnap = await db.collection("users").get();
  const searchIdToUid = {};
  for (const uDoc of usersSnap.docs) {
    const sId = (uDoc.data().searchId || "").trim();
    if (sId) searchIdToUid[sId] = uDoc.id;
    // Firebase UID でも引けるようにフォールバック
    searchIdToUid[uDoc.id] = uDoc.id;
  }

  for (const row of dataRows) {
    const gadgetId = (row[0] || "").trim();
    const userIdOrSearchId = (row[1] || "").trim();
    const name = (row[3] || "").trim();
    if (!userIdOrSearchId || !name) { skipped++; continue; }

    // searchId または Firebase UID からユーザーを解決
    const resolvedUid = searchIdToUid[userIdOrSearchId];
    if (!resolvedUid) { skipped++; continue; }

    const gadgetData = {
      name,
      category: row[4] || "カテゴリなし",
      amazonUrl: row[5] || "",
      amazonAffiliateUrl: row[6] || "",
      rakutenAffiliateUrl: row[7] || "",
      imageUrl: row[8] || "",
      memo: row[9] || "",
    };

    const userRef = db.collection("users").doc(resolvedUid);

    if (gadgetId) {
      const existing = await userRef.collection("gadgets").doc(gadgetId).get();
      if (existing.exists) {
        // データが変わっていなければスキップ（無限ループ防止）
        if (isGadgetDataEqual(existing.data(), gadgetData)) { skipped++; continue; }
        gadgetData.updatedAt = admin.firestore.FieldValue.serverTimestamp();

        await userRef.collection("gadgets").doc(gadgetId).update(gadgetData);
        updated++;
      } else {
        gadgetData.id = gadgetId;
        gadgetData.createdAt = admin.firestore.FieldValue.serverTimestamp();
        gadgetData.updatedAt = admin.firestore.FieldValue.serverTimestamp();

        await userRef.collection("gadgets").doc(gadgetId).set(gadgetData);
        imported++;
      }
    } else {
      gadgetData.createdAt = admin.firestore.FieldValue.serverTimestamp();
      gadgetData.updatedAt = admin.firestore.FieldValue.serverTimestamp();
      const newDoc = await userRef.collection("gadgets").add(gadgetData);
      // Flutter側と同じく、ドキュメントIDをフィールドとしても保存
      await newDoc.update({ id: newDoc.id });
      imported++;
    }
  }

  return { imported, updated, skipped, total: dataRows.length };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// HTTP エンドポイント (手動トリガー用)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.importVenuesFromSheet = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const result = await doImportVenues();
    res.json({ success: true, ...result });
  } catch (e) {
    console.error("Venue import error:", e);
    res.status(500).json({ error: e.message });
  }
});

exports.importGadgetsFromSheet = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const result = await doImportGadgets();
    res.json({ success: true, ...result });
  } catch (e) {
    console.error("Gadget import error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// スケジュール実行: シート → Firestore 自動同期 (5分毎)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.scheduledSyncVenues = functions.pubsub
  .schedule("every 5 minutes")
  .onRun(async () => {
    // シート → Firestore インポート
    try {
      const importResult = await doImportVenues();
      console.log("Scheduled venue import:", JSON.stringify(importResult));
    } catch (e) {
      console.error("Scheduled venue import error:", e.message);
    }
    // Firestore → シート エクスポート
    try {
      const count = await doSyncVenuesToSheet();
      console.log("Scheduled venue sync:", count, "venues");
    } catch (e) {
      console.error("Scheduled venue sync error:", e.message);
    }
  });

exports.scheduledSyncGadgets = functions.pubsub
  .schedule("every 5 minutes")
  .onRun(async () => {
    // シート → Firestore インポート
    try {
      const importResult = await doImportGadgets();
      console.log("Scheduled gadget import:", JSON.stringify(importResult));
    } catch (e) {
      console.error("Scheduled gadget import error:", e.message);
    }
    // Firestore → シート エクスポート
    try {
      const count = await doSyncGadgetsToSheet();
      console.log("Scheduled gadget sync:", count, "gadgets");
    } catch (e) {
      console.error("Scheduled gadget sync error:", e.message);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 景品データ Firestore → Google Sheets 同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function doSyncPrizesToSheet() {
  const prizesSnap = await admin.firestore().collection("prizes")
    .orderBy("name").get();

  const prizeRows = prizesSnap.docs.map((doc) => {
    const p = doc.data();
    return [
      doc.id,
      p.name || "",
      p.category || "",
      p.priceRange || "",
      p.amazonUrl || "",
      p.amazonAffiliateUrl || "",
      p.imageUrl || "",
      p.memo || "",
      p.registeredBy || "",
      p.createdAt ? p.createdAt.toDate().toISOString().split("T")[0] : "",
      typeof p.rating === "number" ? p.rating.toFixed(1) : "0",
      typeof p.reviewCount === "number" ? String(p.reviewCount) : "0",
    ];
  });

  const sheetName = "景品一覧";
  const values = [
    ["景品ID", "景品名", "カテゴリ", "価格帯", "AmazonURL", "アフィリエイトURL", "画像URL", "メモ", "登録者", "登録日", "評価", "レビュー数"],
    ...prizeRows,
  ];

  try {
    await sheetsUpdate(PRIZE_SHEET_ID, `${sheetName}!A1`, values);
  } catch (e) {
    await sheetsAddSheet(PRIZE_SHEET_ID, sheetName);
    await sheetsUpdate(PRIZE_SHEET_ID, `${sheetName}!A1`, values);
  }
  const nextRow = values.length + 1;
  await sheetsClear(PRIZE_SHEET_ID, `${sheetName}!A${nextRow}:L10000`);

  return prizeRows.length;
}

exports.syncPrizesToSheet = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const count = await doSyncPrizesToSheet();
    res.json({ success: true, count });
  } catch (e) {
    console.error("Prize sync error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Firestore トリガー: 景品変更時に自動同期
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.onPrizeWrite = functions.firestore
  .document("prizes/{prizeId}")
  .onWrite(async (change) => {
    if (change.before.exists && change.after.exists) {
      const before = change.before.data();
      const after = change.after.data();
      const fields = ["name", "category", "priceRange", "amazonUrl", "amazonAffiliateUrl", "imageUrl", "memo", "rating", "reviewCount"];
      const changed = fields.some((f) => String(before[f] || "") !== String(after[f] || ""));
      if (!changed) return;
    }
    try {
      const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
      const syncUrl = `https://us-central1-${projectId}.cloudfunctions.net/syncPrizesToSheet`;
      const ac = new AbortController();
      const tid = setTimeout(() => ac.abort(), 30000);
      await fetch(syncUrl, { method: "POST", signal: ac.signal }).finally(() => clearTimeout(tid));
    } catch (e) {
      console.warn("Auto prize sync failed (non-critical):", e.message);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Google Sheets → Firestore インポート (景品) 共通ロジック
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function isPrizeDataEqual(existing, sheetData) {
  const fields = ["name", "category", "priceRange", "amazonUrl", "amazonAffiliateUrl", "imageUrl", "memo"];
  for (const f of fields) {
    if ((existing[f] || "") !== (sheetData[f] || "")) return false;
  }
  return true;
}

async function doImportPrizes() {
  const rows = await sheetsRead(PRIZE_SHEET_ID, "景品一覧!A:L");
  if (rows.length < 2) return { imported: 0, updated: 0, skipped: 0, total: 0 };

  const db = admin.firestore();
  const dataRows = rows.slice(1);
  let imported = 0;
  let updated = 0;
  let skipped = 0;

  for (const row of dataRows) {
    const prizeId = (row[0] || "").trim();
    const name = (row[1] || "").trim();
    if (!name) { skipped++; continue; }

    const prizeData = {
      name,
      category: row[2] || "",
      priceRange: row[3] || "",
      amazonUrl: row[4] || "",
      amazonAffiliateUrl: row[5] || "",
      imageUrl: row[6] || "",
      memo: row[7] || "",
    };

    if (prizeId) {
      const existing = await db.collection("prizes").doc(prizeId).get();
      if (existing.exists) {
        if (isPrizeDataEqual(existing.data(), prizeData)) { skipped++; continue; }
        prizeData.updatedAt = admin.firestore.FieldValue.serverTimestamp();
        await db.collection("prizes").doc(prizeId).update(prizeData);
        updated++;
      } else {
        prizeData.createdAt = admin.firestore.FieldValue.serverTimestamp();
        prizeData.updatedAt = admin.firestore.FieldValue.serverTimestamp();
        prizeData.registeredBy = "sheet_import";
        await db.collection("prizes").doc(prizeId).set(prizeData);
        imported++;
      }
    } else {
      prizeData.createdAt = admin.firestore.FieldValue.serverTimestamp();
      prizeData.updatedAt = admin.firestore.FieldValue.serverTimestamp();
      prizeData.registeredBy = "sheet_import";
      await db.collection("prizes").add(prizeData);
      imported++;
    }
  }

  return { imported, updated, skipped, total: dataRows.length };
}

exports.importPrizesFromSheet = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const result = await doImportPrizes();
    res.json({ success: true, ...result });
  } catch (e) {
    console.error("Prize import error:", e);
    res.status(500).json({ error: e.message });
  }
});

exports.scheduledSyncPrizes = functions.pubsub
  .schedule("every 5 minutes")
  .onRun(async () => {
    try {
      const importResult = await doImportPrizes();
      console.log("Scheduled prize import:", JSON.stringify(importResult));
    } catch (e) {
      console.error("Scheduled prize import error:", e.message);
    }
    try {
      const count = await doSyncPrizesToSheet();
      console.log("Scheduled prize sync:", count, "prizes");
    } catch (e) {
      console.error("Scheduled prize sync error:", e.message);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// トーナメントポイント自動付与
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// 順位係数
function rankMultiplier(rank) {
  switch (rank) {
    case 1: return 3.0;
    case 2: return 2.0;
    case 3: return 1.5;
    case 4: return 1.2;
    default: return 1.0;
  }
}

function calcRankPoints(teamCount, rank) {
  return Math.round(teamCount * rankMultiplier(rank));
}

// ブラケットの決勝結果から全体順位（teamId → 順位）を作る。
// 複数ブラケット（1部/2部/3部…のティア分け）の場合、各ブラケットの決勝勝者を
// 一律 rank 1（優勝）にすると全ティアの勝者が優勝扱いになってしまうため、
// ブラケットの rankRange（例 "5〜8位"）の先頭数字を起点に全体順位へ変換する。
// （順位表ウィジェット _FinalRankingsWidget と同じ考え方）
async function buildTeamRanksFromBrackets(db, tournamentId) {
  const teamRanks = {};
  const bracketsSnap = await db.collection("tournaments").doc(tournamentId).collection("brackets").get();
  for (const bDoc of bracketsSnap.docs) {
    const rankRange = (bDoc.data().rankRange || "").toString();
    const m = rankRange.match(/(\d+)/);
    const rankStart = m ? parseInt(m[1], 10) : 1; // "全チーム"・未設定は 1 位起点

    const matchesSnap = await bDoc.ref.collection("matches")
      .where("status", "==", "completed").get();
    for (const mDoc of matchesSnap.docs) {
      const mData = mDoc.data();
      const result = mData.result || {};
      if (!result.winner) continue;
      const loserId = result.winner === mData.teamAId ? mData.teamBId : mData.teamAId;

      let localRank = null; // ブラケット内順位（勝者側）
      if (mData.round === "final" || mData.round === "final_1st") localRank = 1;
      else if (mData.round === "third_place" || mData.round === "final_3rd") localRank = 3;
      else if (mData.round === "final_5th") localRank = 5;
      else if (mData.round === "final_7th") localRank = 7;
      if (localRank === null) continue;

      teamRanks[result.winner] = rankStart + localRank - 1;
      if (loserId) teamRanks[loserId] = rankStart + localRank;
    }
  }
  return teamRanks;
}

// ※ 主催者ボーナス（calcOrganizerBonus）・連続参加ボーナス（calcStreakBonus）は
//   廃止済み（2026/07）。ポイントは「ポイントの仕組み」に公表している
//   順位ポイントのみとする。

/**
 * 大会のステータスが「終了」に変わったらポイントを自動付与
 */
exports.onTournamentStatusChange = functions.firestore
  .document("tournaments/{tournamentId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    // 体験デモ大会はポイント付与・通知対象外
    if (after.isDemo === true) return null;

    // ステータスが「終了」に変わった場合のみ実行
    if (before.status === "終了" || after.status !== "終了") return null;
    // 二重付与防止
    if (after.pointsAwarded === true) return null;

    const db = admin.firestore();
    const tournamentId = context.params.tournamentId;

    const organizerId = after.organizerId || "";
    const tournamentName = after.title || after.name || "";
    const tournamentDate = after.date || "";

    // エントリーデータ取得
    const entriesSnap = await db.collection("tournaments").doc(tournamentId).collection("entries").get();

    // ポイントは実際に参加したチーム数（エントリー数）を基準に計算する。
    // エントリーが取れない場合のみ maxTeams / currentTeams にフォールバック。
    // （募集枠 maxTeams 基準だと、枠より多い/少ないチーム数で開催された場合に実態とずれる）
    const entryTeamIds = new Set();
    for (const doc of entriesSnap.docs) {
      entryTeamIds.add(doc.data().teamId || doc.id);
    }
    const teamCount = entryTeamIds.size > 0
      ? entryTeamIds.size
      : (after.maxTeams || after.currentTeams || 0);
    if (teamCount === 0) return null;

    console.log(`[Points] Awarding points for tournament: ${tournamentName} (${tournamentId}), teams: ${teamCount}`);
    const userTeamMap = {};  // uid -> teamId
    const teamUserMap = {};  // teamId -> [uids]

    for (const doc of entriesSnap.docs) {
      const data = doc.data();
      const teamId = data.teamId || doc.id;
      if (!teamUserMap[teamId]) teamUserMap[teamId] = [];

      // memberUids から取得（通常エントリー）
      if (data.memberUids && Array.isArray(data.memberUids)) {
        for (const uid of data.memberUids) {
          if (uid) {
            userTeamMap[uid] = teamId;
            teamUserMap[teamId].push(uid);
          }
        }
      }
      // leaderUid から取得（CSV登録でも設定される場合がある）
      if (data.leaderUid) {
        userTeamMap[data.leaderUid] = teamId;
        if (!teamUserMap[teamId].includes(data.leaderUid)) {
          teamUserMap[teamId].push(data.leaderUid);
        }
      }
      // enteredBy から取得
      if (data.enteredBy) {
        userTeamMap[data.enteredBy] = teamId;
        if (!teamUserMap[teamId].includes(data.enteredBy)) {
          teamUserMap[teamId].push(data.enteredBy);
        }
      }
    }

    const allUserIds = Object.keys(userTeamMap);

    // ━━━ 順位取得（ブラケットから・全体順位） ━━━
    const teamRanks = await buildTeamRanksFromBrackets(db, tournamentId);

    // ━━━ ポイント付与 ━━━
    const batch = db.batch();
    const now = new Date();
    const season = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1; // 4月始まり

    const userPointData = {};

    for (const uid of allUserIds) {
      const teamId = userTeamMap[uid];
      const rank = teamRanks[teamId] || 99;
      const rankPoints = calcRankPoints(teamCount, rank);
      const totalEarned = rankPoints;

      const userRef = db.collection("users").doc(uid);
      batch.update(userRef, {
        totalPoints: admin.firestore.FieldValue.increment(totalEarned),
        seasonPoints: admin.firestore.FieldValue.increment(totalEarned),
        "stats.tournamentsPlayed": admin.firestore.FieldValue.increment(1),
        ...(rank === 1 ? { "stats.championships": admin.firestore.FieldValue.increment(1) } : {}),
      });

      // ポイント履歴
      const historyRef = userRef.collection("pointHistory").doc(tournamentId);
      batch.set(historyRef, {
        tournamentId,
        tournamentName,
        date: tournamentDate,
        teamCount,
        rank: rank <= 4 ? rank : null,
        rankPoints,
        streakBonus: 0,
        organizerBonus: 0,
        totalEarned,
        season,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      userPointData[uid] = { totalEarned, rank: rank <= 4 ? rank : null };

      // 通知
      const rankNames = { 1: "優勝", 2: "準優勝", 3: "3位", 4: "4位" };
      const detail = rank <= 4 ? `（${rankNames[rank]}）` : "";

      const notifRef = userRef.collection("notifications").doc();
      batch.set(notifRef, {
        type: "points_earned",
        senderId: "system",
        senderName: "ポイント獲得",
        message: `「${tournamentName}」で +${totalEarned}pt 獲得！${detail}`,
        tournamentId,
        points: totalEarned,
        read: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // ━━━ 主催回数カウント ━━━
    // ※ 主催者ボーナス・連続参加ボーナスは廃止（2026/07）。
    //   「ポイントの仕組み」の公表仕様（順位ポイント＋シーズン制）に実装を合わせる。
    //   主催回数（tournamentsHosted）は統計として引き続きカウントする。
    if (organizerId) {
      batch.update(db.collection("users").doc(organizerId), {
        "stats.tournamentsHosted": admin.firestore.FieldValue.increment(1),
      });
    }

    // 二重付与防止フラグ
    batch.update(change.after.ref, { pointsAwarded: true });

    await batch.commit();
    console.log(`[Points] Awarded points to ${allUserIds.length} users for tournament ${tournamentId}`);
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// フォロワー/フォロイング数の再計算（一括修正）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.recalcFollowCounts = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
    const db = admin.firestore();
    const usersSnap = await db.collection("users").get();
    let updated = 0;

    for (const userDoc of usersSnap.docs) {
      const uid = userDoc.id;
      const data = userDoc.data();

      // サブコレクションの実際のドキュメント数をカウント
      const followersSnap = await db.collection("users").doc(uid).collection("followers").get();
      const followingSnap = await db.collection("users").doc(uid).collection("following").get();

      // 存在しないユーザーを指すドキュメントを除外してカウント
      let validFollowers = 0;
      const followerDeleteBatch = db.batch();
      let hasFollowerDeletes = false;
      for (const fDoc of followersSnap.docs) {
        const followerRef = db.collection("users").doc(fDoc.id);
        const followerUser = await followerRef.get();
        if (followerUser.exists) {
          validFollowers++;
        } else {
          // 削除済みユーザーのフォロワードキュメントを削除
          followerDeleteBatch.delete(fDoc.ref);
          hasFollowerDeletes = true;
        }
      }

      let validFollowing = 0;
      const followingDeleteBatch = db.batch();
      let hasFollowingDeletes = false;
      for (const fDoc of followingSnap.docs) {
        const followingRef = db.collection("users").doc(fDoc.id);
        const followingUser = await followingRef.get();
        if (followingUser.exists) {
          validFollowing++;
        } else {
          // 削除済みユーザーのフォローイングドキュメントを削除
          followingDeleteBatch.delete(fDoc.ref);
          hasFollowingDeletes = true;
        }
      }

      // 削除済みユーザーのドキュメントをクリーンアップ
      if (hasFollowerDeletes) await followerDeleteBatch.commit();
      if (hasFollowingDeletes) await followingDeleteBatch.commit();

      // カウントが一致しない場合のみ更新
      const currentFollowers = data.followersCount || 0;
      const currentFollowing = data.followingCount || 0;

      if (currentFollowers !== validFollowers || currentFollowing !== validFollowing) {
        await db.collection("users").doc(uid).update({
          followersCount: validFollowers,
          followingCount: validFollowing,
        });
        updated++;
        console.log(`[RecalcFollow] ${uid}: followers ${currentFollowers}->${validFollowers}, following ${currentFollowing}->${validFollowing}`);
      }
    }

    res.json({ success: true, totalUsers: usersSnap.size, updated });
  } catch (e) {
    console.error("RecalcFollow error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 登録完了メール送信（プロフィール設定完了時）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// ── onCreate: ドキュメント作成時に profileCompleted: true なら送信 ──
exports.sendWelcomeEmail = functions.firestore
  .document("users/{uid}")
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data.profileCompleted) return null;
    // 体験デモ用の匿名ユーザーにはウェルカムメールを送らない
    if (data.isDemo === true) return null;

    const uid = context.params.uid;
    let email;
    try {
      const userRecord = await admin.auth().getUser(uid);
      // Apple/Googleサインインは認証メールを変更できないため、本人が確認済みの
      // 通知用メールアドレス（users/{uid}/private/info）があればそちらを優先する
      // （無ければ認証メールにフォールバック）
      email = (await resolveNotificationEmail(uid)) || userRecord.email;
    } catch (e) {
      console.error("[WelcomeEmail] Failed to get user:", e.message);
      return null;
    }
    if (!email) return null;

    const nickname = data.nickname || "ユーザー";

    try {
      await sendWelcomeMailTo(email, nickname);
      await snap.ref.update({ welcomeEmailSent: true });
      console.log(`[WelcomeEmail] Sent to ${email} (onCreate)`);
    } catch (e) {
      console.error("[WelcomeEmail] Send failed:", e.message);
    }
    return null;
  });

// ── onUpdate: profileCompleted が false→true に変わったら送信 ──
exports.sendWelcomeEmailOnUpdate = functions.firestore
  .document("users/{uid}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    // 体験デモ用の匿名ユーザーにはウェルカムメールを送らない
    if (after.isDemo === true) return null;

    // profileCompleted が false/未設定 → true に変わった時だけ
    if (before.profileCompleted || !after.profileCompleted) return null;
    // 既にウェルカムメール送信済みならスキップ
    if (after.welcomeEmailSent) return null;

    const uid = context.params.uid;
    let email;
    try {
      const userRecord = await admin.auth().getUser(uid);
      email = (await resolveNotificationEmail(uid)) || userRecord.email;
    } catch (e) {
      console.error("[WelcomeEmail] Failed to get user:", e.message);
      return null;
    }
    if (!email) return null;

    const nickname = after.nickname || "ユーザー";

    try {
      await sendWelcomeMailTo(email, nickname);
      // 重複送信防止フラグ
      await change.after.ref.update({ welcomeEmailSent: true });
      console.log(`[WelcomeEmail] Sent to ${email} (onUpdate)`);
    } catch (e) {
      console.error("[WelcomeEmail] Send failed:", e.message);
    }
    return null;
  });

// 本人が確認済みの通知用メールアドレス（users/{uid}/private/info）があれば返す。
// 無ければ null（呼び出し側で認証メールにフォールバックする）。
async function resolveNotificationEmail(uid) {
  try {
    const snap = await admin.firestore()
      .collection("users").doc(uid).collection("private").doc("info").get();
    if (!snap.exists) return null;
    const d = snap.data() || {};
    return (d.notificationEmailVerified && d.notificationEmail) || null;
  } catch (e) {
    console.error("[resolveNotificationEmail] failed:", e.message);
    return null;
  }
}

// ── ウェルカムメール送信の共通関数 ──
async function sendWelcomeMailTo(email, nickname) {
  const gmailUser = process.env.GMAIL_USER || functions.config().gmail?.user;
  const gmailPass = process.env.GMAIL_PASS || functions.config().gmail?.pass;
  if (!gmailUser || !gmailPass) throw new Error("Gmail credentials not configured");

  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user: gmailUser, pass: gmailPass },
  });

  await transporter.sendMail({
    from: `Sofvo <info@sofvo.com>`,
    to: email,
    subject: "Sofvoへようこそ！登録が完了しました",
    html: `
<div style="background-color:#f7f7f7;padding:40px 0;font-family:'Helvetica Neue',Arial,sans-serif">
  <div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08)">
    <div style="background:linear-gradient(135deg,#1B3A5C,#2E5C8A);padding:32px;text-align:center">
      <h1 style="margin:0;font-size:32px;letter-spacing:3px">
        <span style="color:#ffffff;font-weight:900">Sof</span><span style="color:#C4A962;font-weight:900">vo</span>
      </h1>
      <p style="color:rgba(255,255,255,0.7);margin:8px 0 0;font-size:13px;letter-spacing:1px">ソフトバレーボール マッチングアプリ</p>
    </div>
    <div style="padding:32px">
      <h2 style="color:#1B3A5C;font-size:18px;margin:0 0 16px">${nickname}さん、ようこそ！</h2>
      <p style="color:#6B6B6B;font-size:14px;line-height:1.8;margin:0 0 24px">
        Sofvo へのご登録ありがとうございます。<br>
        アカウントの登録が完了しました。
      </p>
      <table style="width:100%;border-collapse:collapse;margin:0 0 20px">
        <tr>
          <td style="padding:10px 14px;border-bottom:1px solid #f0f0f0;vertical-align:top;width:32px"><span style="font-size:18px">&#x1F3D0;</span></td>
          <td style="padding:10px 14px;border-bottom:1px solid #f0f0f0;color:#6B6B6B;font-size:13px;line-height:1.6"><strong style="color:#1B3A5C">大会をさがす</strong> &ndash; お近くの大会を検索してエントリー</td>
        </tr>
        <tr>
          <td style="padding:10px 14px;border-bottom:1px solid #f0f0f0;vertical-align:top;width:32px"><span style="font-size:18px">&#x1F4AC;</span></td>
          <td style="padding:10px 14px;border-bottom:1px solid #f0f0f0;color:#6B6B6B;font-size:13px;line-height:1.6"><strong style="color:#1B3A5C">タイムライン</strong> &ndash; プレイヤーの投稿をチェック＆共有</td>
        </tr>
        <tr>
          <td style="padding:10px 14px;vertical-align:top;width:32px"><span style="font-size:18px">&#x1F91D;</span></td>
          <td style="padding:10px 14px;color:#6B6B6B;font-size:13px;line-height:1.6"><strong style="color:#1B3A5C">仲間とつながる</strong> &ndash; フォローして情報を共有</td>
        </tr>
      </table>
      <p style="text-align:center;margin:0 0 24px">
        <a href="https://sofvo.com/welcome" style="color:#2E5C8A;font-size:14px;font-weight:bold;text-decoration:none">詳しくはこちら &rarr;</a>
      </p>
      <div style="text-align:center;margin:0 0 8px">
        <a href="https://sofvo.com" style="background-color:#1B3A5C;color:#ffffff;text-decoration:none;padding:14px 48px;border-radius:8px;font-size:15px;font-weight:bold;display:inline-block">Sofvo を開く</a>
      </div>
      <p style="color:#B0B0B0;font-size:12px;line-height:1.6;margin:24px 0 0;border-top:1px solid #eee;padding-top:16px">
        このメールに心当たりがない場合は、このメールを無視してください。
      </p>
    </div>
    <div style="background:#f7f7f7;padding:16px;text-align:center">
      <p style="color:#B0B0B0;font-size:11px;margin:0">&copy; 2026 Sofvo. All rights reserved.</p>
    </div>
  </div>
</div>
    `,
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// アカウント削除完了メール送信
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exports.sendAccountDeletedEmail = functions.firestore
  .document("users/{uid}")
  .onDelete(async (snap, context) => {
    const data = snap.data();
    const uid = context.params.uid;

    // Firestoreドキュメント削除時点ではAuth userはまだ存在する
    // （deleteAccount()ではuserRef.delete()の後にuser.delete()を呼ぶため）
    let email;
    try {
      const authUser = await admin.auth().getUser(uid);
      // private/info はユーザードキュメント削除前にまだ存在するので取得できる
      email = (await resolveNotificationEmail(uid)) || authUser.email;
    } catch (e) {
      // Auth userが既に削除済み or 存在しない場合はスキップ
      console.log(`[DeleteEmail] Auth user not found for ${uid}, skipping`);
      return null;
    }

    if (!email) return null;

    const nickname = data.nickname || "ユーザー";

    try {
      await sendAccountDeletedMailTo(email, nickname);
      console.log(`[DeleteEmail] Sent to ${email}`);
    } catch (e) {
      console.error("[DeleteEmail] Send failed:", e.message);
    }
    return null;
  });

// ── アカウント削除メール送信の共通関数 ──
async function sendAccountDeletedMailTo(email, nickname) {
  const gmailUser = process.env.GMAIL_USER || functions.config().gmail?.user;
  const gmailPass = process.env.GMAIL_PASS || functions.config().gmail?.pass;
  if (!gmailUser || !gmailPass) throw new Error("Gmail credentials not configured");

  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user: gmailUser, pass: gmailPass },
  });

  await transporter.sendMail({
    from: `Sofvo <info@sofvo.com>`,
    to: email,
    subject: "アカウント削除が完了しました - Sofvo",
    html: `
<div style="background-color:#f7f7f7;padding:40px 0;font-family:'Helvetica Neue',Arial,sans-serif">
  <div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08)">
    <div style="background:linear-gradient(135deg,#1B3A5C,#2E5C8A);padding:32px;text-align:center">
      <h1 style="margin:0;font-size:32px;letter-spacing:3px">
        <span style="color:#ffffff;font-weight:900">Sof</span><span style="color:#C4A962;font-weight:900">vo</span>
      </h1>
      <p style="color:rgba(255,255,255,0.7);margin:8px 0 0;font-size:13px;letter-spacing:1px">ソフトバレーボール マッチングアプリ</p>
    </div>
    <div style="padding:32px">
      <h2 style="color:#1B3A5C;font-size:18px;margin:0 0 16px">${nickname}さん</h2>
      <p style="color:#6B6B6B;font-size:14px;line-height:1.8;margin:0 0 24px">
        Sofvo のアカウント削除が完了しました。<br>
        ご利用いただきありがとうございました。
      </p>
      <div style="background:#f8f9fa;border-radius:8px;padding:20px;margin:0 0 24px">
        <p style="color:#6B6B6B;font-size:13px;line-height:1.8;margin:0">
          <strong style="color:#1B3A5C">削除された情報：</strong><br>
          ・プロフィール情報<br>
          ・投稿・コメント・いいね<br>
          ・フォロー・フォロワー情報<br>
          ・大会のエントリー情報
        </p>
      </div>
      <p style="color:#6B6B6B;font-size:14px;line-height:1.8;margin:0 0 24px">
        またいつでもお戻りいただけます。<br>
        新しいアカウントで再登録が可能です。
      </p>
      <div style="text-align:center;margin:0 0 8px">
        <a href="https://sofvo.com" style="background-color:#1B3A5C;color:#ffffff;text-decoration:none;padding:14px 48px;border-radius:8px;font-size:15px;font-weight:bold;display:inline-block">Sofvo を開く</a>
      </div>
      <p style="color:#B0B0B0;font-size:12px;line-height:1.6;margin:24px 0 0;border-top:1px solid #eee;padding-top:16px">
        このメールに心当たりがない場合は、このメールを無視してください。<br>
        ご不明な点がございましたら、お気軽にお問い合わせください。
      </p>
    </div>
    <div style="background:#f7f7f7;padding:16px;text-align:center">
      <p style="color:#B0B0B0;font-size:11px;margin:0">&copy; 2026 Sofvo. All rights reserved.</p>
    </div>
  </div>
</div>
    `,
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 通知用メールアドレス（Apple/Google Sign In等、認証メールを
// 変更できないユーザー向けの代替送信先）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// 本人が新しいメールアドレスを入力 → 確認メールを送る（まだ確定はしない）
exports.requestNotificationEmailVerification = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const email = data && typeof data.email === "string" ? data.email.trim() : "";
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new functions.https.HttpsError("invalid-argument", "正しいメールアドレスを入力してください");
  }

  const db = admin.firestore();
  const token = crypto.randomUUID();

  // メールアドレスは個人情報なので、他ユーザーが読める users/{uid} 本体ではなく
  // 本人のみ読み書きできる private/info サブドキュメントに保存する
  await db.collection("users").doc(uid).collection("private").doc("info").set({
    pendingNotificationEmail: email,
    pendingNotificationEmailToken: token,
    pendingNotificationEmailRequestedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  const userSnap = await db.collection("users").doc(uid).get();
  const nickname = (userSnap.exists && userSnap.data().nickname) || "ユーザー";

  await sendNotificationEmailVerificationMailTo(email, nickname, uid, token);
  return { sent: true };
});

// 確認メール内のリンクから叩かれる（メールクライアントから開かれるためログイン不要）
exports.verifyNotificationEmail = functions.https.onRequest(async (req, res) => {
  const uid = (req.query.uid || "").toString();
  const token = (req.query.token || "").toString();

  const fail = (message) => {
    res.status(400).send(`<!doctype html><html lang="ja"><meta charset="utf-8">
      <body style="font-family:sans-serif;text-align:center;padding:60px 20px;color:#1A1A1A;">
        <h2>確認できませんでした</h2><p>${message}</p>
      </body></html>`);
  };

  if (!uid || !token) return fail("リンクが正しくありません。");

  const db = admin.firestore();
  const userSnap = await db.collection("users").doc(uid).get();
  if (!userSnap.exists) return fail("ユーザーが見つかりません。");

  const privateRef = db.collection("users").doc(uid).collection("private").doc("info");
  const privateSnap = await privateRef.get();
  const privateData = privateSnap.exists ? (privateSnap.data() || {}) : {};
  if (!privateData.pendingNotificationEmailToken || privateData.pendingNotificationEmailToken !== token) {
    return fail("リンクの有効期限が切れているか、既に確認済みです。設定画面から再度お試しください。");
  }

  // 24時間で失効
  const requestedAt = privateData.pendingNotificationEmailRequestedAt;
  if (requestedAt && Date.now() - requestedAt.toMillis() > 24 * 60 * 60 * 1000) {
    await privateRef.update({
      pendingNotificationEmail: admin.firestore.FieldValue.delete(),
      pendingNotificationEmailToken: admin.firestore.FieldValue.delete(),
      pendingNotificationEmailRequestedAt: admin.firestore.FieldValue.delete(),
    });
    return fail("リンクの有効期限が切れています。設定画面から再度お試しください。");
  }

  await privateRef.update({
    notificationEmail: privateData.pendingNotificationEmail,
    notificationEmailVerified: true,
    pendingNotificationEmail: admin.firestore.FieldValue.delete(),
    pendingNotificationEmailToken: admin.firestore.FieldValue.delete(),
    pendingNotificationEmailRequestedAt: admin.firestore.FieldValue.delete(),
  });

  res.status(200).send(`<!doctype html><html lang="ja"><meta charset="utf-8">
    <body style="font-family:sans-serif;text-align:center;padding:60px 20px;color:#1A1A1A;">
      <h2 style="color:#1B3A5C;">確認できました</h2>
      <p>通知用メールアドレスの設定が完了しました。<br>このタブは閉じて構いません。</p>
    </body></html>`);
});

async function sendNotificationEmailVerificationMailTo(email, nickname, uid, token) {
  const gmailUser = process.env.GMAIL_USER || functions.config().gmail?.user;
  const gmailPass = process.env.GMAIL_PASS || functions.config().gmail?.pass;
  if (!gmailUser || !gmailPass) throw new Error("Gmail credentials not configured");

  const transporter = nodemailer.createTransport({
    service: "gmail",
    auth: { user: gmailUser, pass: gmailPass },
  });

  const verifyUrl =
    `https://us-central1-sofvo-19d84.cloudfunctions.net/verifyNotificationEmail` +
    `?uid=${encodeURIComponent(uid)}&token=${encodeURIComponent(token)}`;

  await transporter.sendMail({
    from: `Sofvo <info@sofvo.com>`,
    to: email,
    subject: "通知用メールアドレスの確認 - Sofvo",
    html: `
<div style="background-color:#f7f7f7;padding:40px 0;font-family:'Helvetica Neue',Arial,sans-serif">
  <div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08)">
    <div style="background:linear-gradient(135deg,#1B3A5C,#2E5C8A);padding:32px;text-align:center">
      <h1 style="margin:0;font-size:32px;letter-spacing:3px">
        <span style="color:#ffffff;font-weight:900">Sof</span><span style="color:#C4A962;font-weight:900">vo</span>
      </h1>
    </div>
    <div style="padding:32px">
      <h2 style="color:#1B3A5C;font-size:18px;margin:0 0 16px">${nickname}さん</h2>
      <p style="color:#6B6B6B;font-size:14px;line-height:1.8;margin:0 0 24px">
        このメールアドレスを Sofvo の「通知用メールアドレス」として設定するリクエストを受け付けました。<br>
        下のボタンから確認すると、今後の通知メールがこのアドレスに届くようになります。
      </p>
      <div style="text-align:center;margin:0 0 8px">
        <a href="${verifyUrl}" style="background-color:#1B3A5C;color:#ffffff;text-decoration:none;padding:14px 48px;border-radius:8px;font-size:15px;font-weight:bold;display:inline-block">このメールアドレスを設定する</a>
      </div>
      <p style="color:#B0B0B0;font-size:12px;line-height:1.6;margin:24px 0 0;border-top:1px solid #eee;padding-top:16px">
        リンクの有効期限は24時間です。このメールに心当たりがない場合は、このメールを無視してください（設定は反映されません）。
      </p>
    </div>
    <div style="background:#f7f7f7;padding:16px;text-align:center">
      <p style="color:#B0B0B0;font-size:11px;margin:0">&copy; 2026 Sofvo. All rights reserved.</p>
    </div>
  </div>
</div>
    `,
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// エントリー追加時に currentTeams を自動インクリメント
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onEntryCreated = functions.firestore
  .document("tournaments/{tournamentId}/entries/{entryId}")
  .onCreate(async (snap, context) => {
    const tournamentId = context.params.tournamentId;
    const db = admin.firestore();
    await db.collection("tournaments").doc(tournamentId).update({
      currentTeams: admin.firestore.FieldValue.increment(1),
    });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// エントリー削除時に currentTeams を自動デクリメント
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onEntryDeleted = functions.firestore
  .document("tournaments/{tournamentId}/entries/{entryId}")
  .onDelete(async (snap, context) => {
    const tournamentId = context.params.tournamentId;
    const db = admin.firestore();
    await db.collection("tournaments").doc(tournamentId).update({
      currentTeams: admin.firestore.FieldValue.increment(-1),
    });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 全大会の currentTeams を entries 数から再計算して修復
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.repairCurrentTeams = functions.https.onRequest(async (req, res) => {
  if (!(await assertAdminRequest(req, res))) return;
  const db = admin.firestore();
  const tournamentsSnap = await db.collection("tournaments").get();
  let fixed = 0;

  for (const doc of tournamentsSnap.docs) {
    const entriesSnap = await db.collection("tournaments").doc(doc.id).collection("entries").get();
    const actual = entriesSnap.size;
    const current = doc.data().currentTeams || 0;

    if (actual !== current) {
      await db.collection("tournaments").doc(doc.id).update({ currentTeams: actual });
      fixed++;
      console.log(`Fixed ${doc.id}: ${current} -> ${actual}`);
    }
  }

  res.json({ message: `Repaired ${fixed} tournaments`, total: tournamentsSnap.size });
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 投稿いいね数の自動更新
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onPostLikeCreated = functions.firestore
  .document("posts/{postId}/likes/{likeId}")
  .onCreate(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("posts").doc(context.params.postId).update({
      likesCount: admin.firestore.FieldValue.increment(1),
    });
  });

exports.onPostLikeDeleted = functions.firestore
  .document("posts/{postId}/likes/{likeId}")
  .onDelete(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("posts").doc(context.params.postId).update({
      likesCount: admin.firestore.FieldValue.increment(-1),
    });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 投稿コメント数の自動更新
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onPostCommentCreated = functions.firestore
  .document("posts/{postId}/comments/{commentId}")
  .onCreate(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("posts").doc(context.params.postId).update({
      commentsCount: admin.firestore.FieldValue.increment(1),
    });
  });

exports.onPostCommentDeleted = functions.firestore
  .document("posts/{postId}/comments/{commentId}")
  .onDelete(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("posts").doc(context.params.postId).update({
      commentsCount: admin.firestore.FieldValue.increment(-1),
    });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ユーザー検索用の正規化フィールド（nicknameNorm / searchIdNorm）
// lib/utils/search_normalize.dart と同一仕様。変更時は必ず両方を揃えること。
// 変換順: 全角英数記号→半角 → カタカナ→ひらがな → 空白除去 → 小文字化
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function normalizeForSearch(s) {
  if (!s) return "";
  let out = String(s)
    .replace(/[！-～]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0xFEE0))
    .replace(/[ァ-ヶ]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0x60))
    .replace(/[\s　]/g, "");
  return out.toLowerCase();
}

// users/{uid} が書かれるたびに正規化フィールドを自動維持する。
// どの画面・経路から nickname / searchId を更新しても漏れない。
// （値が変わらなければ再書き込みしないので無限ループしない）
exports.syncUserSearchNorm = functions.firestore
  .document("users/{uid}")
  .onWrite(async (change) => {
    if (!change.after.exists) return null;
    const data = change.after.data() || {};
    const nicknameNorm = normalizeForSearch(data.nickname || "");
    const searchIdNorm = normalizeForSearch(data.searchId || "");
    if (data.nicknameNorm === nicknameNorm && data.searchIdNorm === searchIdNorm) return null;
    return change.after.ref.update({ nicknameNorm, searchIdNorm });
  });

// 既存ユーザーへの一括バックフィル（デプロイ後に1回叩く。何度でも安全）
exports.backfillSearchNorm = functions.https.onRequest(async (req, res) => {
  if (!(await assertAdminRequest(req, res))) return;
  const db = admin.firestore();
  const snap = await db.collection("users").get();
  let updated = 0;
  let batch = db.batch();
  let n = 0;
  for (const doc of snap.docs) {
    const d = doc.data() || {};
    const nicknameNorm = normalizeForSearch(d.nickname || "");
    const searchIdNorm = normalizeForSearch(d.searchId || "");
    if (d.nicknameNorm !== nicknameNorm || d.searchIdNorm !== searchIdNorm) {
      batch.update(doc.ref, { nicknameNorm, searchIdNorm });
      updated++;
      n++;
      if (n >= 400) {
        await batch.commit();
        batch = db.batch();
        n = 0;
      }
    }
  }
  if (n > 0) await batch.commit();
  res.json({ message: `Backfilled ${updated} users`, total: snap.size });
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Instagram 公式投稿の自動同期（@sofvo.official → アプリ公式アカウント）
// 認証情報は secrets/instagram（クライアント不可）に保存。取得した投稿は
// 公式アカウントの通常 posts として保存する → 公式プロフィールの投稿タブと、
// （自動フォロー済みの）全ユーザーのホームに自動表示される（アプリ改修不要）。
//
// 前提: @sofvo.official をビジネス/クリエイターに変更し、Instagram Graph API
// （graph.instagram.com）の長期アクセストークンを取得して setInstagramConfig で登録。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
const IG_API = "https://graph.instagram.com";
const FB_API = "https://graph.facebook.com/v21.0";

async function graphGet(base, path, params) {
  const url = new URL(`${base}/${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.toString());
  const json = await res.json();
  if (!res.ok || json.error) {
    throw new Error(`IG API error: ${JSON.stringify(json.error || json)}`);
  }
  return json;
}

// Instagramログイン方式（graph.instagram.com）
const igGet = (path, params) => graphGet(IG_API, path, params);
// Facebookログイン方式（graph.facebook.com）
const fbGet = (path, params) => graphGet(FB_API, path, params);

async function resolveOfficialAuthor(db, preferredUid) {
  if (preferredUid) {
    const s = await db.collection("users").doc(preferredUid).get();
    if (s.exists) return { uid: s.id, name: s.data().nickname || "Sofvo公式", avatar: s.data().avatarUrl || "" };
  }
  const q = await db.collection("users").where("isOfficial", "==", true).limit(1).get();
  if (q.empty) return null;
  const d = q.docs[0];
  return { uid: d.id, name: d.data().nickname || "Sofvo公式", avatar: d.data().avatarUrl || "" };
}

// 画像を Storage に再保存し、ダウンロードURL（トークン付き）を返す。
// IG の media_url は一時URLのため、そのまま保存すると後で表示できなくなる。
async function saveImageToStorage(url, destPath) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`image fetch ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const bucket = admin.storage().bucket();
  const file = bucket.file(destPath);
  const downloadToken = crypto.randomUUID();
  await file.save(buf, {
    metadata: {
      contentType: res.headers.get("content-type") || "image/jpeg",
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });
  return `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(destPath)}?alt=media&token=${downloadToken}`;
}

async function syncInstagramCore() {
  const db = admin.firestore();
  const cfgSnap = await db.collection("secrets").doc("instagram").get();
  const cfg = cfgSnap.exists ? (cfgSnap.data() || {}) : {};
  const token = cfg.accessToken;
  if (!token) return { skipped: true, reason: "アクセストークン未設定" };

  const author = await resolveOfficialAuthor(db, cfg.officialUid);
  if (!author) return { skipped: true, reason: "公式アカウント（isOfficial）が見つかりません" };

  // 取得方式: facebook（graph.facebook.com/{igUserId}/media）か instagram（/me/media）
  const useFacebook = cfg.provider === "facebook" && cfg.igUserId;
  const get = useFacebook ? fbGet : igGet;
  const mediaPath = useFacebook ? `${cfg.igUserId}/media` : "me/media";

  const media = await get(mediaPath, {
    fields: "id,caption,media_type,media_url,thumbnail_url,permalink,timestamp",
    limit: "25",
    access_token: token,
  });
  const items = Array.isArray(media.data) ? media.data : [];
  let created = 0;
  for (const item of items) {
    const postRef = db.collection("posts").doc(`ig_${item.id}`);
    if ((await postRef.get()).exists) continue; // 既に同期済み

    const imageUrls = [];
    try {
      if (item.media_type === "CAROUSEL_ALBUM") {
        const children = await get(`${item.id}/children`, {
          fields: "id,media_type,media_url,thumbnail_url",
          access_token: token,
        });
        const kids = Array.isArray(children.data) ? children.data : [];
        let n = 0;
        for (const kid of kids) {
          const src = kid.media_type === "VIDEO" ? kid.thumbnail_url : kid.media_url;
          if (!src) continue;
          imageUrls.push(await saveImageToStorage(src, `official_instagram/${item.id}_${n}.jpg`));
          n++;
        }
      } else {
        const src = item.media_type === "VIDEO" ? item.thumbnail_url : item.media_url;
        if (src) imageUrls.push(await saveImageToStorage(src, `official_instagram/${item.id}.jpg`));
      }
    } catch (e) {
      console.error(`[instagram] image save failed (${item.id}):`, e.message);
      continue; // 画像が取れなければスキップ（次回再試行）
    }
    if (imageUrls.length === 0) continue;

    await postRef.set({
      userId: author.uid,
      userNickname: author.name,
      userAvatarUrl: author.avatar,
      text: item.caption || "",
      images: imageUrls,
      likesCount: 0,
      commentsCount: 0,
      autoGenerated: false,
      source: "instagram",
      instagramId: item.id,
      instagramPermalink: item.permalink || "",
      createdAt: item.timestamp
        ? admin.firestore.Timestamp.fromDate(new Date(item.timestamp))
        : admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    created++;
  }
  await db.collection("secrets").doc("instagram").set(
    { lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(), lastError: null },
    { merge: true },
  );
  return { fetched: items.length, created };
}

// onRequest 用の管理者チェック。Authorization: Bearer <Firebase ID トークン> を
// 検証し、users/{uid}.isAdmin === true のときだけ true を返す。
// false のときはレスポンス送信済みなので、呼び出し側は即 return すること。
async function assertAdminRequest(req, res) {
  const authHeader = req.headers.authorization || "";
  if (!authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "Authentication required" });
    return false;
  }
  try {
    const decoded = await admin.auth().verifyIdToken(authHeader.split("Bearer ")[1]);
    const u = await admin.firestore().collection("users").doc(decoded.uid).get();
    if (!(u.exists && u.data().isAdmin === true)) {
      res.status(403).json({ error: "管理者のみ実行できます" });
      return false;
    }
    return true;
  } catch (e) {
    res.status(403).json({ error: "Invalid or expired token" });
    return false;
  }
}

async function assertAdmin(context, db) {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const u = await db.collection("users").doc(context.auth.uid).get();
  if (!(u.exists && u.data().isAdmin === true)) {
    throw new functions.https.HttpsError("permission-denied", "管理者のみ実行できます");
  }
}

// アクセストークン等の登録（管理者のみ）
exports.setInstagramConfig = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  await assertAdmin(context, db);
  const update = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
  if (data && typeof data.accessToken === "string" && data.accessToken.trim()) {
    update.accessToken = data.accessToken.trim();
  }
  if (data && typeof data.officialUid === "string") {
    update.officialUid = data.officialUid.trim();
  }
  await db.collection("secrets").doc("instagram").set(update, { merge: true });
  return { ok: true };
});

// 短期トークン＋アプリシークレット → 長期トークンに交換して保存（ブラウザで開ける）
// 例: /exchangeInstagramToken?token=SHORT&secret=APP_SECRET&officialUid=UID(任意)
// トークン・シークレットはレスポンスに返さない（保存のみ）。
exports.exchangeInstagramToken = functions.https.onRequest(async (req, res) => {
  try {
    const shortToken = String(req.query.token || req.query.shortToken || "").trim();
    const secret = String(req.query.secret || req.query.client_secret || "").trim();
    const officialUid = String(req.query.officialUid || "").trim();
    if (!shortToken || !secret) {
      res.status(400).json({ error: "token（短期トークン）と secret（アプリシークレット）が必要です" });
      return;
    }
    // 短期 → 長期（約60日）に交換
    const exchanged = await igGet("access_token", {
      grant_type: "ig_exchange_token",
      client_secret: secret,
      access_token: shortToken,
    });
    if (!exchanged.access_token) {
      res.status(500).json({ error: "交換に失敗しました", detail: exchanged });
      return;
    }
    const update = {
      accessToken: exchanged.access_token,
      tokenType: "long_lived",
      tokenObtainedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (officialUid) update.officialUid = officialUid;
    await admin.firestore().collection("secrets").doc("instagram").set(update, { merge: true });
    // 期限の目安だけ返す（トークン本体は返さない）
    res.json({ ok: true, expiresInDays: Math.round((exchanged.expires_in || 0) / 86400) });
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
});

// Facebookログイン方式のセットアップ（ブラウザで開ける）
// 短期Facebookトークン → 長期化 → 連携済みIGビジネスアカウントIDとページトークンを
// 自動取得して secrets/instagram に保存。EAA… で始まるトークンはこちらを使う。
// 例: /setupInstagramFacebook?token=EAA...&appId=xxx&secret=yyy&officialUid=UID(任意)
exports.setupInstagramFacebook = functions
  .runWith({ timeoutSeconds: 120 })
  .https.onRequest(async (req, res) => {
    try {
      const shortToken = String(req.query.token || "").trim();
      const appId = String(req.query.appId || req.query.client_id || "").trim();
      const secret = String(req.query.secret || req.query.client_secret || "").trim();
      const officialUid = String(req.query.officialUid || "").trim();
      if (!shortToken || !appId || !secret) {
        res.status(400).json({ error: "token（Facebookトークン）, appId（アプリID）, secret（アプリシークレット）が必要です" });
        return;
      }

      // 1) 短期 → 長期のユーザートークン
      const exchanged = await fbGet("oauth/access_token", {
        grant_type: "fb_exchange_token",
        client_id: appId,
        client_secret: secret,
        fb_exchange_token: shortToken,
      });
      const longUserToken = exchanged.access_token;
      if (!longUserToken) {
        res.status(500).json({ error: "長期トークンへの交換に失敗", detail: exchanged });
        return;
      }

      // 2) 連携ページから IGビジネスアカウントID と ページトークン（長期・実質無期限）を取得
      const pages = await fbGet("me/accounts", {
        fields: "name,access_token,instagram_business_account{id,username}",
        access_token: longUserToken,
      });
      const list = Array.isArray(pages.data) ? pages.data : [];
      const page = list.find((p) => p.instagram_business_account && p.instagram_business_account.id);
      if (!page) {
        res.status(400).json({
          error: "Instagramビジネスアカウントが連携されたFacebookページがOKされていません。@sofvo.official をFacebookページに連携し、認可時に該当ページを選んでください。",
          pagesFound: list.map((p) => p.name),
        });
        return;
      }

      const update = {
        provider: "facebook",
        accessToken: page.access_token, // ページトークン（長期・実質無期限）
        igUserId: page.instagram_business_account.id,
        igUsername: page.instagram_business_account.username || "",
        pageName: page.name || "",
        tokenType: "page_token",
        tokenObtainedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      if (officialUid) update.officialUid = officialUid;
      await admin.firestore().collection("secrets").doc("instagram").set(update, { merge: true });

      res.json({
        ok: true,
        provider: "facebook",
        igUsername: update.igUsername,
        page: update.pageName,
      });
    } catch (e) {
      res.status(500).json({ error: String(e.message || e) });
    }
  });

// 手動同期（ブラウザで開ける。トークンはサーバー側 secrets から読むだけで
// 冪等なので、既存の管理エンドポイントと同様に onRequest とする）
exports.syncInstagramNow = functions
  .runWith({ timeoutSeconds: 300, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    if (!(await assertAdminRequest(req, res))) return;
    try {
      const result = await syncInstagramCore();
      res.json(result);
    } catch (e) {
      await admin.firestore().collection("secrets").doc("instagram").set(
        { lastError: String(e.message || e) }, { merge: true },
      );
      res.status(500).json({ error: String(e.message || e) });
    }
  });

// 定期同期（6時間ごと）
exports.scheduledSyncInstagram = functions
  .runWith({ timeoutSeconds: 300, memory: "512MB" })
  .pubsub.schedule("every 6 hours")
  .onRun(async () => {
    try {
      await syncInstagramCore();
    } catch (e) {
      console.error("[instagram] scheduled sync failed:", e.message);
      await admin.firestore().collection("secrets").doc("instagram").set(
        { lastError: String(e.message || e) }, { merge: true },
      );
    }
    return null;
  });

// 長期トークンの自動延長（10日ごと。60日期限切れの前に更新する）
exports.refreshInstagramToken = functions.pubsub
  .schedule("every 240 hours")
  .onRun(async () => {
    const db = admin.firestore();
    const snap = await db.collection("secrets").doc("instagram").get();
    const cfg = snap.exists ? (snap.data() || {}) : {};
    const token = cfg.accessToken;
    if (!token) return null;
    // Facebookページトークンは実質無期限のため更新不要
    if (cfg.provider === "facebook") return null;
    try {
      const res = await igGet("refresh_access_token", { grant_type: "ig_refresh_token", access_token: token });
      if (res.access_token) {
        await db.collection("secrets").doc("instagram").set(
          { accessToken: res.access_token, tokenRefreshedAt: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true },
        );
      }
    } catch (e) {
      console.error("[instagram] token refresh failed:", e.message);
    }
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 大会タイムラインいいね数の自動更新
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onTimelineLikeCreated = functions.firestore
  .document("tournaments/{tournamentId}/timeline/{postId}/likes/{likeId}")
  .onCreate(async (snap, context) => {
    const { tournamentId, postId } = context.params;
    const db = admin.firestore();
    await db.collection("tournaments").doc(tournamentId)
      .collection("timeline").doc(postId).update({
        likesCount: admin.firestore.FieldValue.increment(1),
      });
  });

exports.onTimelineLikeDeleted = functions.firestore
  .document("tournaments/{tournamentId}/timeline/{postId}/likes/{likeId}")
  .onDelete(async (snap, context) => {
    const { tournamentId, postId } = context.params;
    const db = admin.firestore();
    await db.collection("tournaments").doc(tournamentId)
      .collection("timeline").doc(postId).update({
        likesCount: admin.firestore.FieldValue.increment(-1),
      });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// フォロワー数の自動更新
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onFollowerCreated = functions.firestore
  .document("users/{userId}/followers/{followerId}")
  .onCreate(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("users").doc(context.params.userId).update({
      followersCount: admin.firestore.FieldValue.increment(1),
    });
  });

exports.onFollowerDeleted = functions.firestore
  .document("users/{userId}/followers/{followerId}")
  .onDelete(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("users").doc(context.params.userId).update({
      followersCount: admin.firestore.FieldValue.increment(-1),
    });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// フォロー数の自動更新
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onFollowingCreated = functions.firestore
  .document("users/{userId}/following/{followId}")
  .onCreate(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("users").doc(context.params.userId).update({
      followingCount: admin.firestore.FieldValue.increment(1),
    });
  });

exports.onFollowingDeleted = functions.firestore
  .document("users/{userId}/following/{followId}")
  .onDelete(async (snap, context) => {
    const db = admin.firestore();
    await db.collection("users").doc(context.params.userId).update({
      followingCount: admin.firestore.FieldValue.increment(-1),
    });
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 招待コードの引き換え（相互フォロー＋チーム参加）
// invites/{CODE} = { referrerUid, teamId?, tournamentId?, expiresAt? }
// クライアントは相手側コレクションへ書けない（Firestoreルール）ため、
// admin 権限のこの関数でまとめて確定する。クリップボード等に頼らない確実な経路。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.redeemInvite = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  }
  const uid = context.auth.uid;
  const code = (data && data.code ? String(data.code) : "").trim().toUpperCase();
  if (!code) {
    throw new functions.https.HttpsError("invalid-argument", "招待コードが空です");
  }

  const db = admin.firestore();
  const inviteSnap = await db.collection("invites").doc(code).get();
  if (!inviteSnap.exists) {
    throw new functions.https.HttpsError("not-found", "招待コードが見つかりません");
  }
  const invite = inviteSnap.data() || {};

  // 有効期限チェック
  if (invite.expiresAt && typeof invite.expiresAt.toMillis === "function" &&
      invite.expiresAt.toMillis() < Date.now()) {
    throw new functions.https.HttpsError("failed-precondition", "招待コードの有効期限が切れています");
  }

  const referrerUid = invite.referrerUid || null;
  const result = {
    referrerName: null,
    teamId: null,
    teamName: null,
    tournamentId: invite.tournamentId || null,
    followed: false,
    joinedTeam: false,
    requestedTeam: false,
  };

  // 自分の情報
  const meSnap = await db.collection("users").doc(uid).get();
  const myName = (meSnap.exists && meSnap.data().nickname) || "名前なし";
  const myAvatar = (meSnap.exists && meSnap.data().avatarUrl) || "";

  // ── 相互フォロー（自分以外の紹介者がいる場合のみ）──
  if (referrerUid && referrerUid !== uid) {
    const refSnap = await db.collection("users").doc(referrerUid).get();
    if (refSnap.exists) {
      const refName = refSnap.data().nickname || "名前なし";
      const refAvatar = refSnap.data().avatarUrl || "";
      result.referrerName = refName;

      const now = admin.firestore.FieldValue.serverTimestamp();
      const meRef = db.collection("users").doc(uid);
      const refRef = db.collection("users").doc(referrerUid);

      // 既存判定（カウント二重加算とフォロー通知の重複を避ける）
      const [meFollowsRef, refFollowsMe] = await Promise.all([
        meRef.collection("following").doc(referrerUid).get(),
        refRef.collection("following").doc(uid).get(),
      ]);

      const batch = db.batch();
      if (!meFollowsRef.exists) {
        batch.set(meRef.collection("following").doc(referrerUid), { nickname: refName, avatarUrl: refAvatar, createdAt: now });
        batch.set(refRef.collection("followers").doc(uid), { createdAt: now });
      }
      if (!refFollowsMe.exists) {
        batch.set(refRef.collection("following").doc(uid), { nickname: myName, avatarUrl: myAvatar, createdAt: now });
        batch.set(meRef.collection("followers").doc(referrerUid), { createdAt: now });
      }
      await batch.commit();
      result.followed = true;

      // 紹介者に通知（初回フォロー時のみ）
      if (!meFollowsRef.exists) {
        try {
          await refRef.collection("notifications").add({
            type: "follow",
            senderId: uid,
            senderName: myName,
            senderAvatar: myAvatar,
            message: "があなたをフォローしました",
            read: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        } catch (e) {
          console.error("[redeemInvite] follow notification failed:", e);
        }
      }
    }
  }

  // ── チーム参加リクエスト（teamId 指定時・承認制）──
  // 「同じ招待URLで誰でもチームに入れてしまう」を防ぐため、ここでは直接参加させず
  // teams/{id}/joinRequests/{uid} に参加リクエストを作成し、オーナーの承認を待つ。
  if (invite.teamId) {
    const teamRef = db.collection("teams").doc(invite.teamId);
    const teamSnap = await teamRef.get();
    if (teamSnap.exists) {
      const teamData = teamSnap.data() || {};
      result.teamId = invite.teamId;
      result.teamName = teamData.name || teamData.teamName || "";
      const memberIds = Array.isArray(teamData.memberIds) ? teamData.memberIds : [];

      if (memberIds.includes(uid)) {
        // 既にメンバー（招待者自身など）はそのまま参加扱い
        result.joinedTeam = true;
      } else {
        // 参加リクエストを作成（set でべき等：再引き換えしても重複しない）
        await teamRef.collection("joinRequests").doc(uid).set({
          uid,
          name: myName,
          avatar: myAvatar,
          referrerUid: referrerUid || null,
          status: "pending",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        result.requestedTeam = true;

        // チームオーナーに承認依頼を通知
        const ownerId = teamData.ownerId;
        if (ownerId && ownerId !== uid) {
          try {
            await db.collection("users").doc(ownerId).collection("notifications").add({
              type: "team_join_request",
              teamId: invite.teamId,
              teamName: result.teamName,
              senderId: uid,
              senderName: myName,
              senderAvatar: myAvatar,
              message: `がチーム「${result.teamName}」への参加をリクエストしました`,
              read: false,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          } catch (e) {
            console.error("[redeemInvite] join request notification failed:", e);
          }
        }
      }
    }
  }

  return result;
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// チーム参加リクエストの承認 / 却下（チームオーナーのみ）
// teams/{teamId}/joinRequests/{applicantUid} を処理する。
// 承認時はメンバーへ追加し申請者へ通知、却下時はリクエストを削除する。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.respondTeamJoinRequest = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  }
  const ownerUid = context.auth.uid;
  const teamId = data && data.teamId ? String(data.teamId) : "";
  const applicantUid = data && data.applicantUid ? String(data.applicantUid) : "";
  const approve = !!(data && data.approve);
  if (!teamId || !applicantUid) {
    throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");
  }

  const db = admin.firestore();
  const teamRef = db.collection("teams").doc(teamId);
  const teamSnap = await teamRef.get();
  if (!teamSnap.exists) {
    throw new functions.https.HttpsError("not-found", "チームが見つかりません");
  }
  const teamData = teamSnap.data() || {};
  if (teamData.ownerId !== ownerUid) {
    throw new functions.https.HttpsError("permission-denied", "チームのオーナーのみ操作できます");
  }

  const reqRef = teamRef.collection("joinRequests").doc(applicantUid);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) {
    throw new functions.https.HttpsError("not-found", "参加リクエストが見つかりません");
  }
  const reqData = reqSnap.data() || {};
  const teamName = teamData.name || teamData.teamName || "";

  if (approve) {
    // 申請者の最新プロフィールを取得
    const applicantSnap = await db.collection("users").doc(applicantUid).get();
    const applicantName = (applicantSnap.exists && applicantSnap.data().nickname) || reqData.name || "名前なし";
    const applicantAvatar = (applicantSnap.exists && applicantSnap.data().avatarUrl) || reqData.avatar || "";

    const update = {
      memberIds: admin.firestore.FieldValue.arrayUnion(applicantUid),
    };
    update[`memberNames.${applicantUid}`] = applicantName;
    update[`memberAvatars.${applicantUid}`] = applicantAvatar;
    await teamRef.update(update);
    await reqRef.delete();

    // 申請者に承認を通知
    try {
      await db.collection("users").doc(applicantUid).collection("notifications").add({
        type: "team_join_approved",
        teamId,
        teamName,
        senderId: ownerUid,
        message: `チーム「${teamName}」への参加が承認されました`,
        read: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) {
      console.error("[respondTeamJoinRequest] approve notification failed:", e);
    }
    return { approved: true };
  }

  // 却下：リクエストを削除（通知はしない）
  await reqRef.delete();
  return { approved: false };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// エントリー成立時に参加者へ主催者フォローを自動付与（片方向）
//
// キャプテンはエントリー前に主催者をフォローするが、招待されて追加された
// メンバーは主催者と何の関係もないままだった。そのため主催者の告知投稿が
// タイムラインに流れず、「さがす」のフォロー中にも大会が出なかった。
// 成立時に参加者全員 → 主催者の片方向フォローを張ってこれを解消する。
//
// 逆方向（主催者 → 参加者）は張らない。主催者のフォロー中が1大会で最大
// 数十件ずつ増え、ホームのタイムライン購読（30件ずつ chunk して購読）や
// フォロワー系バッジの集計を圧迫するため。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
async function followOrganizerForEntrants(db, tournamentId, uids) {
  try {
    const targetUids = [...new Set((uids || []).map(String).filter((u) => u))];
    if (targetUids.length === 0) return 0;

    const tSnap = await db.collection("tournaments").doc(tournamentId).get();
    const t = tSnap.exists ? (tSnap.data() || {}) : null;
    if (!t) return 0;
    if (t.isDemo === true) return 0; // 体験デモ大会は実データに影響させない
    const organizerId = t.organizerId ? String(t.organizerId) : "";
    if (!organizerId) return 0;

    const orgRef = db.collection("users").doc(organizerId);
    const orgSnap = await orgRef.get();
    if (!orgSnap.exists) return 0;
    const orgName = orgSnap.data().nickname || "";
    const orgAvatar = orgSnap.data().avatarUrl || "";

    const entrants = targetUids.filter((u) => u !== organizerId);
    if (entrants.length === 0) return 0;

    // 既にフォロー済みの人は書き込まない（followersCount / followingCount の
    // 自動更新トリガーが二重加算されるのを防ぐ）
    const existing = await Promise.all(entrants.map((u) =>
      db.collection("users").doc(u).collection("following").doc(organizerId).get()));

    const now = admin.firestore.FieldValue.serverTimestamp();
    const batch = db.batch();
    let added = 0;
    entrants.forEach((u, i) => {
      if (existing[i].exists) return;
      batch.set(db.collection("users").doc(u).collection("following").doc(organizerId), {
        nickname: orgName,
        avatarUrl: orgAvatar,
        createdAt: now,
      });
      batch.set(orgRef.collection("followers").doc(u), { createdAt: now });
      added++;
    });
    if (added > 0) await batch.commit();
    // 主催者へのフォロー通知は出さない（1大会で数十件届いてしまうため）
    return added;
  } catch (e) {
    console.error("[followOrganizerForEntrants] failed:", e);
    return 0;
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 大会エントリー（承認制・全員承認で成立）
// キャプテンが招待 → 選ばれたメンバー全員が承認して初めて本物の
// entries/{} を作成する。承認が揃うまでは tournaments/{id}/entryDrafts/{} に
// 保持するので、既存のエントリー読み取り箇所（対戦表・人数・収支等）には
// 一切影響しない（＝成立済みエントリーだけが見える）。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.createEntryDraft = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const leaderUid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const teamName = data && data.teamName ? String(data.teamName).trim() : "";
  const memberUids = Array.isArray(data && data.memberUids)
    ? [...new Set(data.memberUids.map(String).filter((u) => u && u !== leaderUid))]
    : [];
  if (!tournamentId || !teamName) throw new functions.https.HttpsError("invalid-argument", "大会・チーム名が必要です");

  const allUids = [leaderUid, ...memberUids];
  if (allUids.length < 4) throw new functions.https.HttpsError("failed-precondition", "メンバーは自分を含めて4人以上必要です");

  const db = admin.firestore();
  const tRef = db.collection("tournaments").doc(tournamentId);

  // 重複チェック：成立エントリー or 承認待ちドラフトに既に含まれる人がいたら弾く
  const [entriesSnap, draftsSnap] = await Promise.all([
    tRef.collection("entries").get(),
    tRef.collection("entryDrafts").get(),
  ]);
  const taken = {};
  entriesSnap.forEach((d) => {
    const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
    uids.forEach((u) => { taken[u] = d.data().teamName || "既存のチーム"; });
  });
  draftsSnap.forEach((d) => {
    const dd = d.data() || {};
    const inv = Array.isArray(dd.invitedUids) ? dd.invitedUids : [];
    inv.forEach((u) => {
      if (!dd.approvals || dd.approvals[u] !== "declined") taken[u] = dd.teamName || "招待中のチーム";
    });
  });
  for (const u of allUids) {
    if (taken[u]) {
      throw new functions.https.HttpsError("failed-precondition",
        `${u === leaderUid ? "あなた" : (memberUids.includes(u) ? "選択したメンバー" : "メンバー")}は既に「${taken[u]}」に含まれています`);
    }
  }

  // 名前・アバター収集＋承認状態の初期化（リーダーは承認済み）
  const memberNames = {};
  const memberAvatars = {};
  const approvals = {};
  await Promise.all(allUids.map(async (u) => {
    const s = await db.collection("users").doc(u).get();
    memberNames[u] = (s.exists && s.data().nickname) || "名前なし";
    memberAvatars[u] = (s.exists && s.data().avatarUrl) || "";
    approvals[u] = (u === leaderUid) ? "approved" : "pending";
  }));

  const tName = ((await tRef.get()).data() || {}).name || "";
  const draftRef = tRef.collection("entryDrafts").doc();
  await draftRef.set({
    teamName,
    leaderUid,
    leaderName: memberNames[leaderUid],
    invitedUids: allUids,
    memberNames,
    memberAvatars,
    approvals,
    status: "pending",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // 招待された各メンバーに承認依頼を通知
  await Promise.all(memberUids.map(async (u) => {
    try {
      await db.collection("users").doc(u).collection("notifications").add({
        type: "entry_invite",
        tournamentId,
        tournamentName: tName,
        draftId: draftRef.id,
        teamName,
        senderId: leaderUid,
        senderName: memberNames[leaderUid],
        senderAvatar: memberAvatars[leaderUid],
        message: `が大会「${tName}」のチーム「${teamName}」に招待しました`,
        read: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { console.error("[createEntryDraft] notify failed:", e); }
  }));

  return { draftId: draftRef.id, invited: memberUids.length };
});

// 招待の承認 / 辞退。全員承認かつ4人以上で本物のエントリーを成立させる。
exports.respondEntryInvite = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  const approve = !!(data && data.approve);
  if (!tournamentId || !draftId) throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");

  const db = admin.firestore();
  const tRef = db.collection("tournaments").doc(tournamentId);
  const draftRef = tRef.collection("entryDrafts").doc(draftId);

  const result = await db.runTransaction(async (tx) => {
    const draftSnap = await tx.get(draftRef);
    if (!draftSnap.exists) throw new functions.https.HttpsError("not-found", "招待が見つかりません（取り消された可能性があります）");
    const draft = draftSnap.data() || {};
    const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
    if (!invited.includes(uid)) throw new functions.https.HttpsError("permission-denied", "この招待の対象ではありません");

    // ── 成立済みエントリーへのメンバー追加（updateEntryMembers 発）──
    // チームは既に成立しているので「全員承認」は不要。追加される本人が
    // 承認した時点でその人だけを本物のエントリーに追加する。
    if (draft.type === "memberAdd") {
      const entryRef = tRef.collection("entries").doc(draft.entryId);
      const entrySnap = await tx.get(entryRef);
      if (!entrySnap.exists) {
        // エントリー自体が削除されていたらドラフトも掃除して終了
        tx.delete(draftRef);
        throw new functions.https.HttpsError("not-found", "エントリーが見つかりません（削除された可能性があります）");
      }
      const approvals = Object.assign({}, draft.approvals || {});
      approvals[uid] = approve ? "approved" : "declined";
      if (approve) {
        // 重複再チェック（トランザクション内）：承認待ちの間に本人が
        // 別チームで成立していないか、成立済みエントリー全体を読み直して確認する。
        // このクエリ読み取りが読み取りセットに入るため、他の成立処理と競合した場合は
        // トランザクションが自動リトライされ、二重所属を確実に防げる。
        const entriesSnap = await tx.get(tRef.collection("entries"));
        let takenTeam = null;
        entriesSnap.forEach((d) => {
          if (d.id === draft.entryId) return;
          const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
          if (uids.includes(uid)) takenTeam = d.data().teamName || "別のチーム";
        });
        if (takenTeam) {
          throw new functions.https.HttpsError("failed-precondition",
            `既に「${takenTeam}」でエントリー成立済みのため、このチームには追加できません`);
        }
        const update = {
          memberUids: admin.firestore.FieldValue.arrayUnion(uid),
        };
        update[`memberNames.${uid}`] = (draft.memberNames || {})[uid] || "名前なし";
        update[`memberAvatars.${uid}`] = (draft.memberAvatars || {})[uid] || "";
        tx.update(entryRef, update);
      }
      const anyPending = invited.some((u) => (approvals[u] || "pending") === "pending");
      if (anyPending) {
        tx.update(draftRef, { approvals });
      } else {
        tx.delete(draftRef);
      }
      return { memberAdd: true, finalized: approve, declined: !approve, teamName: draft.teamName, draft };
    }

    const approvals = Object.assign({}, draft.approvals || {});
    approvals[uid] = approve ? "approved" : "declined";
    // 辞退した人は「全員承認」の判定から除外する（辞退者がリストに残り続ける限り
    // 永遠に成立しない、というのを防ぐため。手動で×取り消しをしなくても、
    // 残りの有効メンバーだけで4人以上揃えば自動的に成立する）。
    const activeInvited = invited.filter((u) => approvals[u] !== "declined");
    const allApproved = activeInvited.length > 0 && activeInvited.every((u) => approvals[u] === "approved");

    if (approve && allApproved && activeInvited.length >= 4) {
      // 成立直前の重複再チェック（トランザクション内）。承認が揃うまでの間に
      // 招待メンバーの誰かが別チームで成立していないか、成立済みエントリー全体を
      // 読み直して確認する。2つの下書きがほぼ同時に成立しようとした場合も、
      // このクエリ読み取りが読み取りセットに入るため一方が自動リトライされ、
      // 重複メンバーでの二重成立を防げる。
      const entriesSnap = await tx.get(tRef.collection("entries"));
      let conflictInfo = null;
      entriesSnap.forEach((d) => {
        const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
        for (const u of activeInvited) {
          if (uids.includes(u)) { conflictInfo = d.data().teamName || "別のチーム"; break; }
        }
      });
      if (conflictInfo) {
        throw new functions.https.HttpsError("failed-precondition",
          `メンバーの誰かが既に「${conflictInfo}」でエントリー成立済みのため、このチームは成立できません。キャプテンがメンバーを見直してください`);
      }
      const activeMemberNames = {};
      const activeMemberAvatars = {};
      activeInvited.forEach((u) => {
        activeMemberNames[u] = (draft.memberNames || {})[u] || "名前なし";
        activeMemberAvatars[u] = (draft.memberAvatars || {})[u] || "";
      });
      const entryRef = tRef.collection("entries").doc();
      tx.set(entryRef, {
        teamId: entryRef.id,
        teamName: draft.teamName,
        leaderUid: draft.leaderUid,
        leaderName: draft.leaderName,
        memberUids: activeInvited,
        memberNames: activeMemberNames,
        memberAvatars: activeMemberAvatars,
        enteredBy: draft.leaderUid,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.delete(draftRef);
      return { finalized: true, teamName: draft.teamName, draft, activeInvited };
    }
    tx.update(draftRef, { approvals });
    return { finalized: false, declined: !approve, teamName: draft.teamName, draft };
  });

  // トランザクション外で通知・タイムライン（成立時のみ本エントリー onEntryCreated が発火）
  if (result.memberAdd) {
    // 追加を承認した本人に主催者フォローを付与（告知が届くように）
    if (result.finalized) await followOrganizerForEntrants(db, tournamentId, [uid]);
    // メンバー追加：承認/辞退をキャプテンに知らせる
    try {
      const meSnap = await db.collection("users").doc(uid).get();
      const myName = (meSnap.exists && meSnap.data().nickname) || "メンバー";
      await db.collection("users").doc(result.draft.leaderUid).collection("notifications").add({
        type: result.finalized ? "entry_confirmed" : "entry_declined",
        tournamentId, teamName: result.teamName,
        senderId: uid, senderName: myName, senderAvatar: "",
        message: result.finalized
          ? `がチーム「${result.teamName}」への追加を承認しました`
          : `がチーム「${result.teamName}」への追加を辞退しました`,
        read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { /* noop */ }
  } else if (result.finalized) {
    // 辞退した人には通知・フォロー付与ともに行わない（正式なメンバーではないため）
    const invited = result.activeInvited || result.draft.invitedUids || [];
    // 参加者全員に主催者フォローを付与（キャプテンは既にフォロー済みなので実質は招待メンバー分）
    await followOrganizerForEntrants(db, tournamentId, invited);
    const tName = ((await tRef.get()).data() || {}).name || "";
    try {
      await tRef.collection("timeline").add({
        authorId: "system", authorName: "システム", authorAvatar: "",
        text: `${result.teamName}がエントリーしました！`,
        isOrganizer: false, pinned: false, likesCount: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { console.error("[respondEntryInvite] timeline failed:", e); }
    await Promise.all(invited.map(async (u) => {
      try {
        await db.collection("users").doc(u).collection("notifications").add({
          type: "entry_confirmed",
          senderId: "system", senderName: "システム", senderAvatar: "",
          tournamentId, tournamentName: tName, teamName: result.teamName,
          message: `チーム「${result.teamName}」のエントリーが成立しました`,
          read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) { /* noop */ }
    }));
  } else if (result.declined) {
    const draft = result.draft;
    try {
      const meSnap = await db.collection("users").doc(uid).get();
      const myName = (meSnap.exists && meSnap.data().nickname) || "メンバー";
      await db.collection("users").doc(draft.leaderUid).collection("notifications").add({
        type: "entry_declined",
        tournamentId, teamName: draft.teamName,
        senderId: uid, senderName: myName, senderAvatar: "",
        message: `が大会チーム「${draft.teamName}」の招待を辞退しました`,
        read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { /* noop */ }
  }

  // 回答した本人の招待通知は「対応済み」にする
  await markEntryInviteNotifications(db, [uid], draftId, { resolved: true });

  return { finalized: result.finalized, declined: !!result.declined, memberAdd: !!result.memberAdd };
});

// 主催者・管理者が、招待された本人に代わって承認する（最終手段）。
// キャプテンは当事者（チームを揃えたい側）で本人の同意なしに参加させられてしまうため対象外。
// 本人がアカウント不整合やアプリ不具合等でどうしても自分で承認できない場合の
// 救済用。respondEntryInvite(approve: true) と同じ成立ロジックを流用するが、
// 呼び出し元が「本人以外」である点が異なるため、誰がいつ代理承認したかを
// approvedByAdmin に記録して監査できるようにする。
exports.adminApproveEntryDraftMember = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const callerUid = context.auth.uid;
  const db = admin.firestore();

  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  const targetUid = data && data.targetUid ? String(data.targetUid) : "";
  if (!tournamentId || !draftId || !targetUid) {
    throw new functions.https.HttpsError("invalid-argument", "tournamentId・draftId・targetUid を指定してください");
  }

  const tRef = db.collection("tournaments").doc(tournamentId);
  const draftRef = tRef.collection("entryDrafts").doc(draftId);

  const [draftSnapPre, tSnapPre, callerSnap] = await Promise.all([
    draftRef.get(), tRef.get(), db.collection("users").doc(callerUid).get(),
  ]);
  if (!draftSnapPre.exists) throw new functions.https.HttpsError("not-found", "招待が見つかりません");
  const draftPre = draftSnapPre.data() || {};
  const organizerId = (tSnapPre.data() || {}).organizerId;
  const isAdmin = callerSnap.data()?.isAdmin === true;
  if (organizerId !== callerUid && !isAdmin) {
    throw new functions.https.HttpsError("permission-denied", "代理承認できるのは主催者・管理者のみです");
  }
  const callerName = (callerSnap.data() || {}).nickname || "管理者";

  const result = await db.runTransaction(async (tx) => {
    const draftSnap = await tx.get(draftRef);
    if (!draftSnap.exists) throw new functions.https.HttpsError("not-found", "招待が見つかりません（取り消された可能性があります）");
    const draft = draftSnap.data() || {};
    const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
    if (!invited.includes(targetUid)) throw new functions.https.HttpsError("not-found", "対象のユーザーはこの招待の対象に含まれていません");

    const approvedByAdmin = Object.assign({}, draft.approvedByAdmin || {});
    approvedByAdmin[targetUid] = { byUid: callerUid, byName: callerName };

    if (draft.type === "memberAdd") {
      const entryRef = tRef.collection("entries").doc(draft.entryId);
      const entrySnap = await tx.get(entryRef);
      if (!entrySnap.exists) {
        tx.delete(draftRef);
        throw new functions.https.HttpsError("not-found", "エントリーが見つかりません（削除された可能性があります）");
      }
      const approvals = Object.assign({}, draft.approvals || {});
      approvals[targetUid] = "approved";
      const entriesSnap = await tx.get(tRef.collection("entries"));
      let takenTeam = null;
      entriesSnap.forEach((d) => {
        if (d.id === draft.entryId) return;
        const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
        if (uids.includes(targetUid)) takenTeam = d.data().teamName || "別のチーム";
      });
      if (takenTeam) {
        throw new functions.https.HttpsError("failed-precondition", `既に「${takenTeam}」でエントリー成立済みのため、このチームには追加できません`);
      }
      const update = { memberUids: admin.firestore.FieldValue.arrayUnion(targetUid) };
      update[`memberNames.${targetUid}`] = (draft.memberNames || {})[targetUid] || "名前なし";
      update[`memberAvatars.${targetUid}`] = (draft.memberAvatars || {})[targetUid] || "";
      tx.update(entryRef, update);
      const anyPending = invited.some((u) => (approvals[u] || "pending") === "pending");
      if (anyPending) {
        tx.update(draftRef, { approvals, approvedByAdmin });
      } else {
        tx.delete(draftRef);
      }
      return { memberAdd: true, finalized: true, teamName: draft.teamName, targetUid };
    }

    const approvals = Object.assign({}, draft.approvals || {});
    approvals[targetUid] = "approved";
    const activeInvited = invited.filter((u) => approvals[u] !== "declined");
    const allApproved = activeInvited.length > 0 && activeInvited.every((u) => approvals[u] === "approved");

    if (allApproved && activeInvited.length >= 4) {
      const entriesSnap = await tx.get(tRef.collection("entries"));
      let conflictInfo = null;
      entriesSnap.forEach((d) => {
        const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
        for (const u of activeInvited) {
          if (uids.includes(u)) { conflictInfo = d.data().teamName || "別のチーム"; break; }
        }
      });
      if (conflictInfo) {
        throw new functions.https.HttpsError("failed-precondition",
          `メンバーの誰かが既に「${conflictInfo}」でエントリー成立済みのため、このチームは成立できません`);
      }
      const activeMemberNames = {};
      const activeMemberAvatars = {};
      activeInvited.forEach((u) => {
        activeMemberNames[u] = (draft.memberNames || {})[u] || "名前なし";
        activeMemberAvatars[u] = (draft.memberAvatars || {})[u] || "";
      });
      const entryRef = tRef.collection("entries").doc();
      tx.set(entryRef, {
        teamId: entryRef.id,
        teamName: draft.teamName,
        leaderUid: draft.leaderUid,
        leaderName: draft.leaderName,
        memberUids: activeInvited,
        memberNames: activeMemberNames,
        memberAvatars: activeMemberAvatars,
        enteredBy: draft.leaderUid,
        adminApprovals: approvedByAdmin,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.delete(draftRef);
      return { finalized: true, teamName: draft.teamName, activeInvited, targetUid };
    }
    tx.update(draftRef, { approvals, approvedByAdmin });
    return { finalized: false, teamName: draft.teamName, targetUid, leaderUid: draft.leaderUid };
  });

  // 代理承認された本人に知らせる
  try {
    const tName = (tSnapPre.data() || {}).name || "";
    await db.collection("users").doc(targetUid).collection("notifications").add({
      type: "entry_confirmed",
      senderId: callerUid, senderName: callerName, senderAvatar: "",
      tournamentId, tournamentName: tName, teamName: result.teamName,
      message: result.finalized
        ? `がチーム「${result.teamName}」への参加を代わりに承認し、エントリーが成立しました`
        : `がチーム「${result.teamName}」への参加を代わりに承認しました`,
      read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) { console.error("[adminApproveEntryDraftMember] notify target failed:", e); }

  if (result.finalized && !result.memberAdd) {
    const invited = result.activeInvited || [];
    await followOrganizerForEntrants(db, tournamentId, invited);
    const tName = (tSnapPre.data() || {}).name || "";
    try {
      await tRef.collection("timeline").add({
        authorId: "system", authorName: "システム", authorAvatar: "",
        text: `${result.teamName}がエントリーしました！`,
        isOrganizer: false, pinned: false, likesCount: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { console.error("[adminApproveEntryDraftMember] timeline failed:", e); }
    await Promise.all(invited.filter((u) => u !== targetUid).map(async (u) => {
      try {
        await db.collection("users").doc(u).collection("notifications").add({
          type: "entry_confirmed",
          senderId: "system", senderName: "システム", senderAvatar: "",
          tournamentId, tournamentName: tName, teamName: result.teamName,
          message: `チーム「${result.teamName}」のエントリーが成立しました`,
          read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) { /* noop */ }
    }));
  } else if (result.finalized && result.memberAdd) {
    await followOrganizerForEntrants(db, tournamentId, [targetUid]);
  }

  // 代理承認された本人の招待通知も「対応済み」にする
  await markEntryInviteNotifications(db, [targetUid], draftId, { resolved: true });

  return { approved: true, finalized: !!result.finalized, teamName: result.teamName };
});

// 招待された本人が承認待ちバナーを開いた（＝招待を目にした）ことを記録する。
// キャプテン側に「既読・未回答」/「未読」を出し分けるためだけの軽量な既読フラグ。
// 承認/辞退の判定には一切使わない（approvals が唯一の正）。
exports.markEntryDraftSeen = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  if (!tournamentId || !draftId) throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");

  const db = admin.firestore();
  const draftRef = db.collection("tournaments").doc(tournamentId).collection("entryDrafts").doc(draftId);
  const snap = await draftRef.get();
  if (!snap.exists) return { ok: false };
  const draft = snap.data() || {};
  const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
  if (!invited.includes(uid)) throw new functions.https.HttpsError("permission-denied", "この招待の対象ではありません");
  if ((draft.seenAt || {})[uid]) return { ok: true, alreadySeen: true };

  await draftRef.update({ [`seenAt.${uid}`]: admin.firestore.FieldValue.serverTimestamp() });
  return { ok: true };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 成立済みエントリーの編集（チーム名・メンバー入替）— キャプテンのみ
// 削除・チーム名変更は即時反映。追加メンバーは entryDrafts
// （type: memberAdd）に隔離し、本人が respondEntryInvite で承認した
// 時点で本物のエントリーに追加する。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.updateEntryMembers = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const entryId = data && data.entryId ? String(data.entryId) : "";
  const teamName = data && data.teamName ? String(data.teamName).trim() : "";
  const memberUids = Array.isArray(data && data.memberUids)
    ? [...new Set(data.memberUids.map(String).filter((u) => u && u !== uid))]
    : [];
  if (!tournamentId || !entryId || !teamName) {
    throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");
  }

  const db = admin.firestore();
  const tRef = db.collection("tournaments").doc(tournamentId);
  const entryRef = tRef.collection("entries").doc(entryId);
  const entrySnap = await entryRef.get();
  if (!entrySnap.exists) throw new functions.https.HttpsError("not-found", "エントリーが見つかりません");
  const entry = entrySnap.data() || {};
  if (entry.leaderUid !== uid) {
    throw new functions.https.HttpsError("permission-denied", "編集できるのはエントリーしたキャプテンのみです");
  }

  const desired = [uid, ...memberUids];
  if (desired.length < 4) {
    throw new functions.https.HttpsError("failed-precondition", "メンバーは自分を含めて4人以上必要です");
  }

  const currentUids = Array.isArray(entry.memberUids) ? entry.memberUids : [];
  const removed = currentUids.filter((u) => u !== uid && !desired.includes(u));
  const added = memberUids.filter((u) => !currentUids.includes(u));

  // 追加メンバーの重複チェック（他の成立エントリー＋承認待ちドラフト）
  if (added.length > 0) {
    const [entriesSnap, draftsSnap] = await Promise.all([
      tRef.collection("entries").get(),
      tRef.collection("entryDrafts").get(),
    ]);
    const taken = {};
    entriesSnap.forEach((d) => {
      if (d.id === entryId) return;
      const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
      uids.forEach((u) => { taken[u] = d.data().teamName || "既存のチーム"; });
    });
    draftsSnap.forEach((d) => {
      const dd = d.data() || {};
      const inv = Array.isArray(dd.invitedUids) ? dd.invitedUids : [];
      inv.forEach((u) => {
        if (!dd.approvals || dd.approvals[u] !== "declined") taken[u] = dd.teamName || "招待中のチーム";
      });
    });
    for (const u of added) {
      if (taken[u]) {
        throw new functions.https.HttpsError("failed-precondition", `選択したメンバーは既に「${taken[u]}」に含まれています`);
      }
    }
  }

  // キャプテンの最新ニックネーム
  const meSnap = await db.collection("users").doc(uid).get();
  const leaderName = (meSnap.exists && meSnap.data().nickname) || entry.leaderName || "名前なし";

  // ── 即時反映：チーム名・リーダー名・削除 ──
  const update = { teamName, leaderName };
  if (removed.length > 0) {
    update.memberUids = admin.firestore.FieldValue.arrayRemove(...removed);
    removed.forEach((u) => {
      update[`memberNames.${u}`] = admin.firestore.FieldValue.delete();
      update[`memberAvatars.${u}`] = admin.firestore.FieldValue.delete();
    });
  }
  await entryRef.update(update);

  // ── 追加メンバー：承認待ちドラフトを作成して招待通知 ──
  if (added.length > 0) {
    const memberNames = {};
    const memberAvatars = {};
    const approvals = { [uid]: "approved" };
    await Promise.all(added.map(async (u) => {
      const s = await db.collection("users").doc(u).get();
      memberNames[u] = (s.exists && s.data().nickname) || "名前なし";
      memberAvatars[u] = (s.exists && s.data().avatarUrl) || "";
      approvals[u] = "pending";
    }));
    memberNames[uid] = leaderName;
    memberAvatars[uid] = (meSnap.exists && meSnap.data().avatarUrl) || "";

    const tName = ((await tRef.get()).data() || {}).name || "";
    const draftRef = tRef.collection("entryDrafts").doc();
    await draftRef.set({
      type: "memberAdd",
      entryId,
      teamName,
      leaderUid: uid,
      leaderName,
      invitedUids: [uid, ...added],
      memberNames,
      memberAvatars,
      approvals,
      status: "pending",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await Promise.all(added.map(async (u) => {
      try {
        await db.collection("users").doc(u).collection("notifications").add({
          type: "entry_invite",
          tournamentId,
          tournamentName: tName,
          draftId: draftRef.id,
          teamName,
          senderId: uid,
          senderName: leaderName,
          senderAvatar: memberAvatars[uid],
          message: `が大会「${tName}」のチーム「${teamName}」に招待しました`,
          read: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) { console.error("[updateEntryMembers] notify failed:", e); }
    }));
  }

  return { added: added.length, removed: removed.length };
});

// 承認待ちエントリー（ドラフト）の取り消し（キャプテン本人 or 主催者）
// 承認待ちエントリーの「招待されました」通知（entry_invite）に状態フラグを付ける。
// 通知一覧で「取り消し済み」「対応済み」と表示し、タップしても承認/辞退ダイアログを出さないため。
//   fields = { canceled: true } … エントリーが取り消された／メンバーから外された
//   fields = { resolved: true } … 本人が回答済み、またはエントリーが成立した
async function markEntryInviteNotifications(db, uids, draftId, fields) {
  await Promise.all(uids.map(async (u) => {
    try {
      const qs = await db.collection("users").doc(u).collection("notifications")
        .where("type", "==", "entry_invite").where("draftId", "==", draftId).get();
      await Promise.all(qs.docs.map((d) => d.ref.update(fields)));
    } catch (e) { console.error("[markEntryInviteNotifications] failed:", u, e); }
  }));
}

// 承認待ちドラフトが消えた（成立・取り消し・辞退による自動成立など、どの経路でも）
// → 招待されていた全員の招待通知を「対応済み」にする。取り消しの場合は cancelEntryDraft 側で
//   canceled も付けており、アプリは canceled を優先して「取り消し済み」と表示する。
exports.onEntryDraftDeleted = functions.firestore
  .document("tournaments/{tournamentId}/entryDrafts/{draftId}")
  .onDelete(async (snap, context) => {
    const draft = snap.data() || {};
    const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
    await markEntryInviteNotifications(admin.firestore(), invited, context.params.draftId, { resolved: true });
    return null;
  });

exports.cancelEntryDraft = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  if (!tournamentId || !draftId) throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");
  const db = admin.firestore();
  const tRef = db.collection("tournaments").doc(tournamentId);
  const draftRef = tRef.collection("entryDrafts").doc(draftId);
  const snap = await draftRef.get();
  if (!snap.exists) return { canceled: true };
  const draft = snap.data() || {};
  const [tSnap, callerSnap] = await Promise.all([tRef.get(), db.collection("users").doc(uid).get()]);
  const tData = tSnap.data() || {};
  const isLeader = draft.leaderUid === uid;
  const isAdmin = callerSnap.data()?.isAdmin === true;
  if (!isLeader && tData.organizerId !== uid && !isAdmin) {
    throw new functions.https.HttpsError("permission-denied", "取り消せるのはキャプテン・主催者・管理者のみです");
  }
  await draftRef.delete();

  // 招待されていたメンバー全員（取り消した本人以外）に知らせる。
  // 以前は通知が無く、承認待ちの表示が黙って消えるだけだった。
  const teamName = draft.teamName || "";
  const isMemberAdd = draft.type === "memberAdd";
  const what = isMemberAdd ? `チーム「${teamName}」へのメンバー追加` : `チーム「${teamName}」のエントリー`;
  const callerData = callerSnap.data() || {};
  // 主催者でない管理者が取り消した場合は個人名を出さず「Sofvo運営」とする
  const senderName = (isLeader || tData.organizerId === uid) ? (callerData.nickname || "メンバー") : "Sofvo運営";
  const senderAvatar = (isLeader || tData.organizerId === uid) ? (callerData.avatarUrl || "") : "";
  const tLabel = tData.name ? `大会「${tData.name}」の` : "";
  const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
  await Promise.all(invited.filter((u) => u !== uid).map(async (u) => {
    try {
      await db.collection("users").doc(u).collection("notifications").add({
        type: "entry_canceled",
        tournamentId, tournamentName: tData.name || "", teamName,
        senderId: uid, senderName, senderAvatar,
        message: isLeader ? `が${tLabel}${what}を取りやめました` : `が${tLabel}${what}を取り消しました`,
        read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { console.error("[cancelEntryDraft] notify failed:", u, e); }
  }));
  await markEntryInviteNotifications(db, invited, draftId, { canceled: true });
  return { canceled: true };
});

// 承認待ちドラフトから特定のメンバー1人だけを取り消す（キャプテンのみ）。
// 残りが全員承認済みになった場合はこのタイミングで成立させる
// （respondEntryInvite 以外の経路で承認が揃うケースのため、同じ成立判定をここでも行う）。
exports.removeEntryDraftMember = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  const targetUid = data && data.targetUid ? String(data.targetUid) : "";
  if (!tournamentId || !draftId || !targetUid) {
    throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");
  }
  const db = admin.firestore();
  const tRef = db.collection("tournaments").doc(tournamentId);
  const draftRef = tRef.collection("entryDrafts").doc(draftId);

  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(draftRef);
    if (!snap.exists) throw new functions.https.HttpsError("not-found", "招待が見つかりません（取り消された可能性があります）");
    const draft = snap.data() || {};
    if (draft.leaderUid !== uid) {
      throw new functions.https.HttpsError("permission-denied", "取り消せるのはキャプテンのみです");
    }
    if (targetUid === uid) {
      throw new functions.https.HttpsError("invalid-argument", "自分自身は取り消せません。招待全体の取り消しを使ってください");
    }
    const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
    if (!invited.includes(targetUid)) {
      throw new functions.https.HttpsError("not-found", "対象のメンバーは招待に含まれていません");
    }
    const remaining = invited.filter((u) => u !== targetUid);
    const targetName = (draft.memberNames || {})[targetUid] || "メンバー";
    const approvals = Object.assign({}, draft.approvals || {});
    const memberNames = Object.assign({}, draft.memberNames || {});
    const memberAvatars = Object.assign({}, draft.memberAvatars || {});
    delete approvals[targetUid];
    delete memberNames[targetUid];
    delete memberAvatars[targetUid];

    if (draft.type === "memberAdd") {
      if (remaining.length <= 1) {
        tx.delete(draftRef);
        return { teamName: draft.teamName, targetName, finalized: false };
      }
      tx.update(draftRef, { invitedUids: remaining, approvals, memberNames, memberAvatars });
      return { teamName: draft.teamName, targetName, finalized: false };
    }

    // 辞退した人は「全員承認」の判定・最低人数のカウントから除外する
    // （×で外さなくても、残りの有効メンバーだけで揃えば自動成立させるため）
    const activeRemaining = remaining.filter((u) => approvals[u] !== "declined");
    if (activeRemaining.length < 4) {
      throw new functions.https.HttpsError("failed-precondition",
        "有効なメンバーが自分を含めて4人未満になるため、このメンバーだけ取り消せません。招待全体を取り消してください");
    }

    const allApproved = activeRemaining.every((u) => approvals[u] === "approved");
    if (allApproved) {
      // 残りの有効メンバーが既に全員承認済みなら、このタイミングで成立させる
      const entriesSnap = await tx.get(tRef.collection("entries"));
      let conflictInfo = null;
      entriesSnap.forEach((d) => {
        const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
        for (const u of activeRemaining) {
          if (uids.includes(u)) { conflictInfo = d.data().teamName || "別のチーム"; break; }
        }
      });
      if (conflictInfo) {
        throw new functions.https.HttpsError("failed-precondition",
          `メンバーの誰かが既に「${conflictInfo}」でエントリー成立済みのため成立できません`);
      }
      const finalMemberNames = {};
      const finalMemberAvatars = {};
      activeRemaining.forEach((u) => {
        finalMemberNames[u] = memberNames[u];
        finalMemberAvatars[u] = memberAvatars[u];
      });
      const entryRef = tRef.collection("entries").doc();
      tx.set(entryRef, {
        teamId: entryRef.id,
        teamName: draft.teamName,
        leaderUid: draft.leaderUid,
        leaderName: draft.leaderName,
        memberUids: activeRemaining,
        memberNames: finalMemberNames,
        memberAvatars: finalMemberAvatars,
        enteredBy: draft.leaderUid,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.delete(draftRef);
      return { teamName: draft.teamName, targetName, finalized: true, invited: activeRemaining };
    }

    tx.update(draftRef, { invitedUids: remaining, approvals, memberNames, memberAvatars });
    return { teamName: draft.teamName, targetName, finalized: false };
  });

  if (result.finalized) {
    const finalizedInvited = result.invited || [];
    await followOrganizerForEntrants(db, tournamentId, finalizedInvited);
    const tName = ((await tRef.get()).data() || {}).name || "";
    try {
      await tRef.collection("timeline").add({
        authorId: "system", authorName: "システム", authorAvatar: "",
        text: `${result.teamName}がエントリーしました！`,
        isOrganizer: false, pinned: false, likesCount: 0,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) { console.error("[removeEntryDraftMember] timeline failed:", e); }
    await Promise.all(finalizedInvited.map(async (u) => {
      try {
        await db.collection("users").doc(u).collection("notifications").add({
          type: "entry_confirmed",
          senderId: "system", senderName: "システム", senderAvatar: "",
          tournamentId, tournamentName: tName, teamName: result.teamName,
          message: `チーム「${result.teamName}」のエントリーが成立しました`,
          read: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) { console.error("[removeEntryDraftMember] notify failed:", e); }
    }));
  }

  // 外されたメンバーの「招待されました」通知を取り消し済みにする
  await markEntryInviteNotifications(db, [targetUid], draftId, { canceled: true });

  return { removed: true, teamName: result.teamName, targetName: result.targetName, finalized: !!result.finalized };
});

// 承認待ちドラフトに、追加でメンバー1人を招待する（キャプテンのみ）。
// 既存の承認状態はそのまま維持し、追加した本人だけが新たに pending になる。
exports.addEntryDraftMember = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  const targetUid = data && data.targetUid ? String(data.targetUid) : "";
  if (!tournamentId || !draftId || !targetUid) {
    throw new functions.https.HttpsError("invalid-argument", "パラメータが不足しています");
  }
  if (targetUid === uid) throw new functions.https.HttpsError("invalid-argument", "自分自身は招待できません");

  const db = admin.firestore();
  const tRef = db.collection("tournaments").doc(tournamentId);
  const draftRef = tRef.collection("entryDrafts").doc(draftId);

  const draftSnap = await draftRef.get();
  if (!draftSnap.exists) throw new functions.https.HttpsError("not-found", "招待が見つかりません（取り消された可能性があります）");
  const draft = draftSnap.data() || {};
  if (draft.leaderUid !== uid) {
    throw new functions.https.HttpsError("permission-denied", "追加できるのはキャプテンのみです");
  }
  const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
  if (invited.includes(targetUid)) {
    throw new functions.https.HttpsError("failed-precondition", "既に招待に含まれています");
  }

  // 重複チェック：他の成立エントリー or 承認待ちドラフト（辞退済みを除く）に既に含まれていないか
  const [entriesSnap, draftsSnap] = await Promise.all([
    tRef.collection("entries").get(),
    tRef.collection("entryDrafts").get(),
  ]);
  let takenTeam = null;
  entriesSnap.forEach((d) => {
    const uids = Array.isArray(d.data().memberUids) ? d.data().memberUids : [];
    if (uids.includes(targetUid)) takenTeam = d.data().teamName || "既存のチーム";
  });
  draftsSnap.forEach((d) => {
    const dd = d.data() || {};
    const inv = Array.isArray(dd.invitedUids) ? dd.invitedUids : [];
    if (inv.includes(targetUid) && (!dd.approvals || dd.approvals[targetUid] !== "declined")) {
      takenTeam = dd.teamName || "招待中のチーム";
    }
  });
  if (takenTeam) {
    throw new functions.https.HttpsError("failed-precondition", `選択したメンバーは既に「${takenTeam}」に含まれています`);
  }

  const targetSnap = await db.collection("users").doc(targetUid).get();
  const targetName = (targetSnap.exists && targetSnap.data().nickname) || "名前なし";
  const targetAvatar = (targetSnap.exists && targetSnap.data().avatarUrl) || "";

  await draftRef.update({
    invitedUids: admin.firestore.FieldValue.arrayUnion(targetUid),
    [`approvals.${targetUid}`]: "pending",
    [`memberNames.${targetUid}`]: targetName,
    [`memberAvatars.${targetUid}`]: targetAvatar,
  });

  const tName = ((await tRef.get()).data() || {}).name || "";
  try {
    await db.collection("users").doc(targetUid).collection("notifications").add({
      type: "entry_invite",
      tournamentId,
      tournamentName: tName,
      draftId,
      teamName: draft.teamName,
      senderId: uid,
      senderName: draft.leaderName || "",
      senderAvatar: (draft.memberAvatars || {})[uid] || "",
      message: `が大会「${tName}」のチーム「${draft.teamName}」に招待しました`,
      read: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) { console.error("[addEntryDraftMember] notify failed:", e); }

  return { added: true, name: targetName };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ポイント付与（サーバーサイド）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.distributePoints = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");

  const { tournamentId, tournamentName, userPoints } = data;
  if (!tournamentId || !userPoints || !Array.isArray(userPoints)) {
    throw new functions.https.HttpsError("invalid-argument", "パラメータが不正です");
  }

  // 主催者権限チェック
  const db = admin.firestore();
  const tournDoc = await db.collection("tournaments").doc(tournamentId).get();
  if (!tournDoc.exists) throw new functions.https.HttpsError("not-found", "大会が見つかりません");
  const tournData = tournDoc.data();
  const isOrganizer = tournData.organizerId === context.auth.uid;
  const isEditor = (tournData.editors || []).includes(context.auth.uid);
  if (!isOrganizer && !isEditor) {
    throw new functions.https.HttpsError("permission-denied", "権限がありません");
  }

  const batch = db.batch();
  for (const entry of userPoints) {
    const { uid, rankPoints, rank } = entry;
    const userRef = db.collection("users").doc(uid);
    const updateData = {
      totalPoints: admin.firestore.FieldValue.increment(rankPoints),
      seasonPoints: admin.firestore.FieldValue.increment(rankPoints),
      "stats.tournamentsPlayed": admin.firestore.FieldValue.increment(1),
    };
    if (rank === 1) updateData["stats.championships"] = admin.firestore.FieldValue.increment(1);
    batch.update(userRef, updateData);

    const historyRef = userRef.collection("pointHistory").doc(tournamentId);
    batch.set(historyRef, {
      tournamentId,
      tournamentName: tournamentName || "",
      rankPoints,
      totalEarned: rankPoints,
      rank: rank <= 8 ? rank : null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();
  return { success: true, updated: userPoints.length };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 既に付与済みの大会ポイントを実参加チーム数基準で再計算して差分補正する
// （付与基準を変更した際の過去分修正用。順位ごとの係数で再計算するため
//   優勝チームだけでなく全参加者がそれぞれの順位の新ポイントに補正される）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 共通コア: 指定大会のポイントを実参加チーム数基準で再計算して差分補正する。
// 履歴の現在値から目標値への差分を加算するため、複数回実行しても安全（2回目以降は差分0）。
async function recomputeTournamentPointsCore(tournamentId) {
  const db = admin.firestore();
  const tournDoc = await db.collection("tournaments").doc(tournamentId).get();
  if (!tournDoc.exists) {
    return { ok: false, code: "not-found", message: "大会が見つかりません" };
  }
  const tournData = tournDoc.data();

  const now = new Date();
  const currentSeason = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1;

  // 付与対象 UID を収集（エントリー参加者＋主催者）。collectionGroup を使わず、
  // 各 users/{uid}/pointHistory/{tournamentId} を直接読むためインデックス不要。
  const uidSet = new Set();
  const userTeamMap = {}; // uid → teamId（順位の再導出用）
  const entriesSnap = await db.collection("tournaments").doc(tournamentId).collection("entries").get();
  for (const eDoc of entriesSnap.docs) {
    const e = eDoc.data();
    const entryTeamId = e.teamId || eDoc.id;
    if (Array.isArray(e.memberUids)) {
      for (const uid of e.memberUids) { if (uid) { uidSet.add(uid); userTeamMap[uid] = entryTeamId; } }
    }
    if (e.leaderUid) { uidSet.add(e.leaderUid); userTeamMap[e.leaderUid] = entryTeamId; }
    if (e.enteredBy) { uidSet.add(e.enteredBy); userTeamMap[e.enteredBy] = entryTeamId; }
  }
  if (tournData.organizerId) uidSet.add(tournData.organizerId);

  // 新しい基準チーム数: 実際に参加したチーム数（エントリー数）。
  // エントリーが取れない場合のみ maxTeams / currentTeams にフォールバック。
  const entryTeamIds = new Set();
  for (const eDoc of entriesSnap.docs) {
    entryTeamIds.add(eDoc.data().teamId || eDoc.id);
  }
  const newTeamCount = entryTeamIds.size > 0
    ? entryTeamIds.size
    : (tournData.maxTeams || tournData.currentTeams || 0);
  if (newTeamCount === 0) {
    return { ok: false, code: "failed-precondition", message: "参加チーム数が0です" };
  }

  // 順位もブラケットから再導出する（保存済みの rank は
  // 「全ブラケットの決勝勝者が優勝扱い」だった旧バグの値を含むため信用しない）
  const teamRanks = await buildTeamRanksFromBrackets(db, tournamentId);

  // 各 UID の pointHistory/{tournamentId} を取得
  const histRefs = [...uidSet].map((uid) =>
    db.collection("users").doc(uid).collection("pointHistory").doc(tournamentId));
  const histDocs = histRefs.length > 0 ? await db.getAll(...histRefs) : [];

  const batch = db.batch();
  let adjustedUsers = 0;
  let totalDiff = 0;
  let historyDocs = 0;
  const tournamentName = tournData.title || tournData.name || "";

  for (const hDoc of histDocs) {
    if (!hDoc.exists) continue; // ポイント未付与のユーザーはスキップ
    historyDocs += 1;
    const userRef = hDoc.ref.parent.parent; // users/{uid}
    if (!userRef) continue;
    const d = hDoc.data();

    const oldTotal = d.totalEarned || 0;
    const oldRank = d.rank || 99; // 1〜8 か null(=99: 参加)

    // 順位はブラケットから再導出した値を使う
    const uid = userRef.id;
    const teamId = userTeamMap[uid];
    const newRank = (teamId && teamRanks[teamId]) || 99;
    const mult = rankMultiplier(newRank);

    // 元々ランクポイント(参加含む)があった人のみ再計算（主催者のみの人は0のまま）
    const hadRankPoints = (d.rankPoints || 0) > 0;
    const newRankPoints = hadRankPoints ? Math.round(newTeamCount * mult) : 0;

    // 主催者ボーナス・連続参加ボーナスは廃止（2026/07）→ 補正時に0へ巻き戻す
    const newTotal = newRankPoints;
    const diff = newTotal - oldTotal;

    // 優勝数の補正（旧バグで複数チームが優勝扱いになっていた分を巻き戻す）
    let champDiff = 0;
    if (hadRankPoints) {
      if (oldRank === 1 && newRank !== 1) champDiff = -1;
      if (oldRank !== 1 && newRank === 1) champDiff = 1;
    }

    // 履歴を新しい値に更新（rank も再導出値で上書き・廃止ボーナスは0に）
    batch.update(hDoc.ref, {
      teamCount: newTeamCount,
      rankPoints: newRankPoints,
      organizerBonus: 0,
      streakBonus: 0,
      totalEarned: newTotal,
      rank: hadRankPoints && newRank <= 8 ? newRank : null,
    });

    if (diff !== 0 || champDiff !== 0) {
      const userUpdate = {};
      if (diff !== 0) {
        userUpdate.totalPoints = admin.firestore.FieldValue.increment(diff);
        // シーズンポイントは同一シーズンのときだけ補正（過去シーズン分は既にリセット済み）
        if ((d.season || currentSeason) === currentSeason) {
          userUpdate.seasonPoints = admin.firestore.FieldValue.increment(diff);
        }
      }
      if (champDiff !== 0) {
        userUpdate["stats.championships"] = admin.firestore.FieldValue.increment(champDiff);
      }
      batch.update(userRef, userUpdate);

      if (diff !== 0) {
        // 補正通知（ポイントが変わった人にのみ）
        const notifRef = userRef.collection("notifications").doc();
        const sign = diff > 0 ? "+" : "";
        batch.set(notifRef, {
          type: "points_earned",
          senderId: "system",
          senderName: "ポイント補正",
          message: `「${tournamentName}」のポイントを再計算しました（${sign}${diff}pt）。`,
          tournamentId,
          points: diff,
          read: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      adjustedUsers += 1;
      totalDiff += diff;
    }
  }

  await batch.commit();
  return {
    ok: true,
    tournamentId,
    newTeamCount,
    historyDocs,
    adjustedUsers,
    totalDiff,
  };
}

// アプリから呼ぶ callable（主催者・編集者・管理者のみ）
exports.recomputeTournamentPoints = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");

  const { tournamentId } = data || {};
  if (!tournamentId) {
    throw new functions.https.HttpsError("invalid-argument", "tournamentId が必要です");
  }

  const db = admin.firestore();
  const tournDoc = await db.collection("tournaments").doc(tournamentId).get();
  if (!tournDoc.exists) throw new functions.https.HttpsError("not-found", "大会が見つかりません");
  const tournData = tournDoc.data();

  // 権限チェック: 主催者・編集者・管理者のみ
  const callerDoc = await db.collection("users").doc(context.auth.uid).get();
  const isAdmin = callerDoc.exists && callerDoc.data().isAdmin === true;
  const isOrganizer = tournData.organizerId === context.auth.uid;
  const isEditor = (tournData.editors || []).includes(context.auth.uid);
  if (!isOrganizer && !isEditor && !isAdmin) {
    throw new functions.https.HttpsError("permission-denied", "権限がありません");
  }

  const result = await recomputeTournamentPointsCore(tournamentId);
  if (!result.ok) throw new functions.https.HttpsError(result.code, result.message);
  return result;
});

// 手動実行用 HTTP エンドポイント（curl で叩く）。
// 例: .../recomputeTournamentPointsNow?tournamentId=XXXX
// 履歴の現在値→目標値の差分補正なので冪等（重複実行しても二重加算されない）。
const recomputeTournamentPointsHttpHandler = async (req, res) => {
  try {
    const db = admin.firestore();
    let tournamentId = req.query.tournamentId || (req.body && req.body.tournamentId);

    // tournamentId が無ければ title から解決（例: ?title=試合結果自動集計アプリ導入大会）
    const title = req.query.title || (req.body && req.body.title);
    if (!tournamentId && title) {
      const q = await db.collection("tournaments").where("title", "==", title).limit(2).get();
      if (q.empty) {
        res.status(404).json({ ok: false, message: `title「${title}」の大会が見つかりません` });
        return;
      }
      if (q.size > 1) {
        res.status(409).json({ ok: false, message: `title「${title}」が複数あります。tournamentId で指定してください`, ids: q.docs.map((d) => d.id) });
        return;
      }
      tournamentId = q.docs[0].id;
    }

    if (!tournamentId) {
      res.status(400).json({ ok: false, message: "tournamentId または title クエリパラメータが必要です" });
      return;
    }

    const result = await recomputeTournamentPointsCore(tournamentId);
    res.status(result.ok ? 200 : 400).json(result);
  } catch (e) {
    console.error("[recomputeTournamentPointsNow]", e);
    res.status(500).json({ ok: false, message: String(e) });
  }
};

exports.recomputeTournamentPointsNow = functions.https.onRequest(recomputeTournamentPointsHttpHandler);

// 旧 recomputeTournamentPointsNow に公開呼び出し権限（allUsers invoker）が
// 付いておらず 403 になるため、新しい関数名でも公開する（新規作成時は権限が付く）。
exports.recomputeTournamentPointsV2 = functions.https.onRequest(recomputeTournamentPointsHttpHandler);

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 大会作成時にフォロワーへ通知
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onTournamentCreate = functions.firestore
  .document("tournaments/{tournamentId}")
  .onCreate(async (snap, context) => {
    const db = admin.firestore();
    const data = snap.data();
    const organizerId = data.organizerId || "";
    const tournamentName = data.title || "";
    const tournamentId = context.params.tournamentId;

    if (!organizerId || !tournamentName) return null;

    // 主催者のフォロワー一覧を取得
    const followersSnap = await db
      .collection("users").doc(organizerId)
      .collection("followers").get();

    if (followersSnap.empty) return null;

    // 主催者のアバター取得
    const userDoc = await db.collection("users").doc(organizerId).get();
    const userData = userDoc.data() || {};
    const organizerName = userData.nickname || userData.displayName || "";
    const organizerAvatar = userData.avatarUrl || "";

    // フォロワーに通知を送信（バッチ上限500件ずつ）
    const followerIds = followersSnap.docs.map((d) => d.id);
    const batchSize = 450;
    for (let i = 0; i < followerIds.length; i += batchSize) {
      const batch = db.batch();
      const chunk = followerIds.slice(i, i + batchSize);
      for (const followerId of chunk) {
        const ref = db.collection("users").doc(followerId)
          .collection("notifications").doc();
        batch.set(ref, {
          type: "tournament_created",
          senderId: organizerId,
          senderName: organizerName,
          senderAvatar: organizerAvatar,
          message: `${organizerName}さんが「${tournamentName}」の募集を開始しました`,
          tournamentId: tournamentId,
          read: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }

    console.log(`[TournamentCreated] Notified ${followerIds.length} followers of ${organizerName}'s tournament: ${tournamentName}`);
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 保存した大会の締切接近 & 残り枠通知（毎日9時に実行）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.checkBookmarkAlerts = functions.pubsub
  .schedule("0 9 * * *")
  .timeZone("Asia/Tokyo")
  .onRun(async () => {
    const db = admin.firestore();

    // 募集中の大会を取得
    const tournamentsSnap = await db.collection("tournaments")
      .where("status", "==", "募集中")
      .get();

    if (tournamentsSnap.empty) return null;

    const now = new Date();
    const todayStr = `${now.getFullYear()}/${String(now.getMonth() + 1).padStart(2, "0")}/${String(now.getDate()).padStart(2, "0")}`;

    for (const tDoc of tournamentsSnap.docs) {
      const t = tDoc.data();
      const tournamentId = tDoc.id;
      const tournamentName = t.title || "";
      const deadline = t.deadline || "";
      const maxTeams = t.maxTeams || 0;
      const currentTeams = t.currentTeams || 0;
      const remaining = maxTeams - currentTeams;

      // 締切日までの残り日数を計算
      let daysLeft = -1;
      if (deadline) {
        const deadlineDate = new Date(deadline.replace(/\//g, "-"));
        const diffMs = deadlineDate.getTime() - now.getTime();
        daysLeft = Math.ceil(diffMs / (1000 * 60 * 60 * 24));
      }

      const shouldNotifyDeadline = daysLeft >= 0 && daysLeft <= 3;
      const shouldNotifySlots = remaining > 0 && remaining <= 2;

      if (!shouldNotifyDeadline && !shouldNotifySlots) continue;

      // この大会をブックマークしているユーザーを検索
      const usersSnap = await db.collectionGroup("bookmarks")
        .where("targetId", "==", tournamentId)
        .where("type", "==", "tournament")
        .get();

      if (usersSnap.empty) continue;

      const batch = db.batch();
      let count = 0;

      for (const bDoc of usersSnap.docs) {
        // パスから userId を取得: users/{uid}/bookmarks/{docId}
        const userId = bDoc.ref.parent.parent.id;
        const alerts = bDoc.data().alerts || [];

        // 締切通知（まだ送っていない場合）
        if (shouldNotifyDeadline && !alerts.includes("deadline")) {
          const ref = db.collection("users").doc(userId)
            .collection("notifications").doc();
          const msg = daysLeft === 0
            ? `「${tournamentName}」のエントリー締切は本日です！`
            : `「${tournamentName}」のエントリー締切まであと${daysLeft}日です`;
          batch.set(ref, {
            type: "deadline_approaching",
            senderId: "system",
            senderName: "システム",
            senderAvatar: "",
            message: msg,
            tournamentId: tournamentId,
            read: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          // alerts に deadline を追加して二重送信防止
          batch.update(bDoc.ref, {
            alerts: admin.firestore.FieldValue.arrayUnion("deadline"),
          });
          count++;
        }

        // 残り枠通知（まだ送っていない場合）
        if (shouldNotifySlots && !alerts.includes("slots")) {
          const ref = db.collection("users").doc(userId)
            .collection("notifications").doc();
          batch.set(ref, {
            type: "slots_low",
            senderId: "system",
            senderName: "システム",
            senderAvatar: "",
            message: `「${tournamentName}」の残り枠があと${remaining}チームです！`,
            tournamentId: tournamentId,
            read: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          batch.update(bDoc.ref, {
            alerts: admin.firestore.FieldValue.arrayUnion("slots"),
          });
          count++;
        }
      }

      if (count > 0) {
        await batch.commit();
        console.log(`[BookmarkAlerts] ${tournamentName}: sent ${count} notifications`);
      }
    }

    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// エントリー締切日（deadline）経過後も募集中/満員のままの大会 → エントリー締切（毎日 JST 0:15）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function normalizeTournamentDeadlineSlash_(deadline) {
  const m = String(deadline).trim().match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/);
  if (!m) return null;
  return `${m[1]}/${String(m[2]).padStart(2, "0")}/${String(m[3]).padStart(2, "0")}`;
}

function jstTodaySlashString_() {
  const s = new Date().toLocaleString("en-US", { timeZone: "Asia/Tokyo" });
  const d = new Date(s);
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${yyyy}/${mm}/${dd}`;
}

exports.autoCloseTournamentEntriesByDeadline = functions.pubsub
  .schedule("15 0 * * *")
  .timeZone("Asia/Tokyo")
  .onRun(async () => {
    const db = admin.firestore();
    const todayStr = jstTodaySlashString_();
    const snap = await db.collection("tournaments")
      .where("status", "in", ["募集中", "満員"])
      .get();
    if (snap.empty) {
      functions.logger.info("autoCloseTournamentEntriesByDeadline: no open tournaments");
      return null;
    }

    let batch = db.batch();
    let pending = 0;
    let updated = 0;

    for (const doc of snap.docs) {
      const dl = doc.data().deadline;
      if (!dl) continue;
      const norm = normalizeTournamentDeadlineSlash_(dl);
      if (!norm || norm >= todayStr) continue;
      batch.update(doc.ref, { status: "エントリー締切" });
      pending++;
      updated++;
      if (pending >= 450) {
        await batch.commit();
        batch = db.batch();
        pending = 0;
      }
    }
    if (pending > 0) await batch.commit();

    functions.logger.info(
      `autoCloseTournamentEntriesByDeadline: todayStr=${todayStr} updated=${updated} scanned=${snap.size}`
    );
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 体験デモ（ログイン不要）の使い捨てデータを定期削除
//   - isDemo:true の大会（サブコレクション含む）を再帰削除
//   - isDemo:true の匿名ユーザー（Firestore ドキュメント + Auth アカウント）を削除
//   いずれも作成から DEMO_TTL_HOURS 経過したものが対象。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
const DEMO_TTL_HOURS = 2;

exports.cleanupDemoData = functions.pubsub
  .schedule("*/15 * * * *") // 15分ごと（デモのゲスト/大会が長く残らないようにする）
  .timeZone("Asia/Tokyo")
  .onRun(async () => {
    const db = admin.firestore();
    const cutoff = admin.firestore.Timestamp.fromMillis(
      Date.now() - DEMO_TTL_HOURS * 60 * 60 * 1000
    );

    let deletedTournaments = 0;
    let deletedUsers = 0;

    // 1. デモ大会を再帰削除
    try {
      const tournSnap = await db
        .collection("tournaments")
        .where("isDemo", "==", true)
        .get();
      for (const doc of tournSnap.docs) {
        const createdAt = doc.data().createdAt;
        if (createdAt && createdAt.toMillis && createdAt.toMillis() > cutoff.toMillis()) {
          continue; // まだ新しい（体験中の可能性）
        }
        await db.recursiveDelete(doc.ref);
        deletedTournaments++;
      }
    } catch (e) {
      functions.logger.error("cleanupDemoData tournaments error", e);
    }

    // 2. デモユーザーを削除（Firestore + Auth）
    try {
      const usersSnap = await db
        .collection("users")
        .where("isDemo", "==", true)
        .get();
      for (const doc of usersSnap.docs) {
        const createdAt = doc.data().createdAt;
        if (createdAt && createdAt.toMillis && createdAt.toMillis() > cutoff.toMillis()) {
          continue;
        }
        // ── 実アカウント保護ガード ──
        // デモは匿名セッション限定のはずだが、旧ビルドの不具合等で実アカウントに
        // isDemo:true が付く（汚染される）ことがある。公式/管理者フラグ持ち、または
        // Auth 側にメール等のログイン手段がある実ユーザーは削除せず、
        // isDemo フラグだけ外して自己修復する。
        const data = doc.data();
        let isRealAccount = data.isOfficial === true || data.isAdmin === true;
        if (!isRealAccount) {
          try {
            const authUser = await admin.auth().getUser(doc.id);
            isRealAccount = !!(authUser.email || (authUser.providerData || []).length > 0);
          } catch (e) {
            // Auth に存在しない（Firestore ドキュメントだけ残っている）→ 削除してよい
          }
        }
        if (isRealAccount) {
          await doc.ref.update({ isDemo: admin.firestore.FieldValue.delete() });
          functions.logger.error(
            `cleanupDemoData: 実アカウント ${doc.id} に isDemo:true が付いていたため、削除せず isDemo を外しました（デモ汚染の可能性。nickname 等は要確認）`
          );
          continue;
        }
        await db.recursiveDelete(doc.ref);
        try {
          await admin.auth().deleteUser(doc.id);
        } catch (e) {
          // Auth アカウントが既に無い場合等は無視
        }
        deletedUsers++;
      }
    } catch (e) {
      functions.logger.error("cleanupDemoData users error", e);
    }

    functions.logger.info(
      `cleanupDemoData: deletedTournaments=${deletedTournaments} deletedUsers=${deletedUsers}`
    );
    return null;
  });

// ── テスト送信用（管理者のみ） ──
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 招待ページ用: 公開プロフィール取得（未認証OK）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.getPublicProfile = functions.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }

  const uid = req.query.uid;
  if (!uid) { res.status(400).json({error: "uid is required"}); return; }

  try {
    const doc = await admin.firestore().collection("users").doc(uid).get();
    if (!doc.exists) { res.status(404).json({error: "user not found"}); return; }
    const data = doc.data();
    res.json({
      nickname: data.nickname || null,
      avatarUrl: data.avatarUrl || null,
    });
  } catch (e) {
    res.status(500).json({error: e.message});
  }
});

exports.testWelcomeEmail = functions.https.onRequest(async (req, res) => {
  if (!(await assertAdminRequest(req, res))) return;
  try {
    const email = req.body.email || req.query.email;
    const nickname = req.body.nickname || req.query.nickname || "テストユーザー";
    if (!email) {
      res.status(400).json({ error: "email が必要です" });
      return;
    }

    await sendWelcomeMailTo(email, nickname);
    res.json({ success: true, message: `${email} に送信しました` });
  } catch (e) {
    console.error("[testWelcomeEmail] Error:", e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── 管理者によるユーザー削除（Firestore 再帰削除 + Auth 削除・管理者のみ） ──
// テストアカウント等を管理者画面から安全に削除するための callable。
// クライアントからは相手ユーザーの Auth を消せない/サブコレクションを再帰削除できないため、
// admin 権限を持つ Cloud Function で確定する。
exports.adminDeleteUser = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  await assertAdmin(context, db);

  const uid = data && typeof data.uid === "string" ? data.uid.trim() : "";
  if (!uid) {
    throw new functions.https.HttpsError("invalid-argument", "削除対象のUIDが必要です");
  }
  if (uid === context.auth.uid) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "自分自身のアカウントは削除できません",
    );
  }

  const userRef = db.collection("users").doc(uid);
  const snap = await userRef.get();
  const nickname = snap.exists ? snap.data().nickname || "" : "";

  // Auth を先に削除しておくと、users ドキュメント削除時に走る
  // sendAccountDeletedEmail（onDelete）が getUser 失敗でスキップされ、
  // 管理者削除で不要な「削除完了メール」が本人へ飛ばない。
  let authDeleted = false;
  try {
    await admin.auth().deleteUser(uid);
    authDeleted = true;
  } catch (e) {
    // Auth に存在しない（Firestore ドキュメントだけ残っている）場合等は無視
    functions.logger.warn(
      `adminDeleteUser: auth delete skipped for ${uid}: ${e.message}`,
    );
  }

  // Firestore ユーザードキュメントをサブコレクションごと再帰削除
  await db.recursiveDelete(userRef);

  functions.logger.info(
    `adminDeleteUser: ${context.auth.uid} deleted ${uid} (${nickname}) authDeleted=${authDeleted}`,
  );
  return { ok: true, uid, nickname, authDeleted };
});

// ── 一時デバッグ用: 2ユーザー間のフォロー関係を診断（管理者のみ）──
// 「相互フォローのはずなのにエントリー画面のメンバー選択に出てこない」等の
// 調査用。following/followers の食い違いや、相手のユーザー本体ドキュメントが
// 存在するか（エントリー画面のピッカーが doc.exists で弾いていないか）を返す。
// uidA/uidB を直接指定するか、nameA/nameB でニックネーム検索も可能
// （完全一致のみ。曖昧・ヒットなしの場合は候補一覧またはエラーを返す）。
exports.debugFollowRelation = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  await assertAdmin(context, db);

  async function resolveUser(label, uidParam, nameParam) {
    if (uidParam) {
      const doc = await db.collection("users").doc(String(uidParam)).get();
      return { uid: String(uidParam), doc };
    }
    if (nameParam) {
      const norm = normalizeForSearch(String(nameParam));
      const snap = await db.collection("users").where("nicknameNorm", "==", norm).limit(10).get();
      if (snap.size === 0) {
        throw new functions.https.HttpsError(
          "not-found",
          `${label}: 「${nameParam}」に一致するユーザーが見つかりません`,
        );
      }
      if (snap.size > 1) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `${label}: 「${nameParam}」に一致するユーザーが複数います。uid${label}で指定し直してください: ` +
            snap.docs.map((d) => `${d.data().nickname || ""}(${d.id})`).join(", "),
        );
      }
      return { uid: snap.docs[0].id, doc: snap.docs[0] };
    }
    throw new functions.https.HttpsError("invalid-argument", `uid${label} または name${label} を指定してください`);
  }

  const a = await resolveUser("A", data && data.uidA, data && data.nameA);
  const b = await resolveUser("B", data && data.uidB, data && data.nameB);
  const uidA = a.uid;
  const uidB = b.uid;

  const [
    userADoc, userBDoc,
    aFollowsBDoc, bFollowsADoc,
    bFollowersHasADoc, aFollowersHasBDoc,
  ] = await Promise.all([
    Promise.resolve(a.doc),
    Promise.resolve(b.doc),
    db.collection("users").doc(uidA).collection("following").doc(uidB).get(),
    db.collection("users").doc(uidB).collection("following").doc(uidA).get(),
    db.collection("users").doc(uidB).collection("followers").doc(uidA).get(),
    db.collection("users").doc(uidA).collection("followers").doc(uidB).get(),
  ]);

  const mismatches = [];
  if (!userADoc.exists) mismatches.push("Aのユーザー本体ドキュメントが存在しません（削除済みアカウントの可能性）");
  if (!userBDoc.exists) mismatches.push("Bのユーザー本体ドキュメントが存在しません（削除済みアカウントの可能性）");
  if (aFollowsBDoc.exists !== bFollowersHasADoc.exists) {
    mismatches.push(
      `A→B: following(${aFollowsBDoc.exists}) と B側のfollowers(${bFollowersHasADoc.exists}) が食い違っています`,
    );
  }
  if (bFollowsADoc.exists !== aFollowersHasBDoc.exists) {
    mismatches.push(
      `B→A: following(${bFollowsADoc.exists}) と A側のfollowers(${aFollowersHasBDoc.exists}) が食い違っています`,
    );
  }
  if (aFollowsBDoc.exists && !userBDoc.exists) {
    mismatches.push("AはBをフォロー中と記録されているが、Bの本体ドキュメントが無いため、AのエントリーメンバーピッカーにBは出ません");
  }
  if (bFollowsADoc.exists && !userADoc.exists) {
    mismatches.push("BはAをフォロー中と記録されているが、Aの本体ドキュメントが無いため、BのエントリーメンバーピッカーにAは出ません");
  }

  return {
    a: { uid: uidA, exists: userADoc.exists, nickname: userADoc.exists ? (userADoc.data().nickname || null) : null },
    b: { uid: uidB, exists: userBDoc.exists, nickname: userBDoc.exists ? (userBDoc.data().nickname || null) : null },
    aFollowsB: aFollowsBDoc.exists,
    bFollowsA: bFollowsADoc.exists,
    // FollowerMemberPicker と同じ条件（following doc + 相手の本体ドキュメントが存在）
    aCanSelectBInEntry: aFollowsBDoc.exists && userBDoc.exists,
    bCanSelectAInEntry: bFollowsADoc.exists && userADoc.exists,
    mismatches,
  };
});

// ── 一時デバッグ用: 1ユーザーのフォロー中/フォロワー一覧を確認（管理者のみ）──
// 公式アカウント等、アプリのマイページではフォロー数を非表示にしているユーザーでも
// 中身を確認できるようにするための管理者用ツール。
exports.debugFollowList = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  await assertAdmin(context, db);

  let uid = data && data.uid ? String(data.uid) : "";
  let userSnap = null;
  if (!uid && data && data.name) {
    const norm = normalizeForSearch(String(data.name));
    const snap = await db.collection("users").where("nicknameNorm", "==", norm).limit(10).get();
    if (snap.size === 0) {
      throw new functions.https.HttpsError("not-found", `「${data.name}」に一致するユーザーが見つかりません`);
    }
    if (snap.size > 1) {
      throw new functions.https.HttpsError("failed-precondition",
        `「${data.name}」に一致するユーザーが複数います: ` +
          snap.docs.map((d) => `${d.data().nickname || ""}(${d.id})`).join(", "));
    }
    uid = snap.docs[0].id;
    userSnap = snap.docs[0];
  }
  if (!uid) throw new functions.https.HttpsError("invalid-argument", "uid または name を指定してください");
  if (!userSnap) userSnap = await db.collection("users").doc(uid).get();

  const [followingSnap, followersSnap] = await Promise.all([
    db.collection("users").doc(uid).collection("following").get(),
    db.collection("users").doc(uid).collection("followers").get(),
  ]);
  const toList = (snap) => snap.docs.map((d) => ({ uid: d.id, nickname: (d.data().nickname || "").toString() }));

  return {
    uid,
    nickname: userSnap.exists ? (userSnap.data().nickname || null) : null,
    isOfficial: userSnap.exists && userSnap.data().isOfficial === true,
    followingCount: followingSnap.size,
    followersCount: followersSnap.size,
    following: toList(followingSnap),
    followers: toList(followersSnap),
  };
});

// ── 一時デバッグ用: 特定ユーザーの大会エントリー招待状況を確認（管理者のみ）──
// 「招待した側が、ちゃんと相手に届いているか知りたい」の確認用。
// entryDrafts（全大会横断）での招待状況（承認/既読/未読）と、
// 本人の notifications に entry_invite が実際に作成されているかを返す。
exports.debugEntryInviteStatus = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  await assertAdmin(context, db);

  let uid = data && data.uid ? String(data.uid) : "";
  let userSnap = null;
  if (!uid && data && data.name) {
    const norm = normalizeForSearch(String(data.name));
    const snap = await db.collection("users").where("nicknameNorm", "==", norm).limit(10).get();
    if (snap.size === 0) {
      throw new functions.https.HttpsError("not-found", `「${data.name}」に一致するユーザーが見つかりません`);
    }
    if (snap.size > 1) {
      throw new functions.https.HttpsError("failed-precondition",
        `「${data.name}」に一致するユーザーが複数います: ` +
          snap.docs.map((d) => `${d.data().nickname || ""}(${d.id})`).join(", "));
    }
    uid = snap.docs[0].id;
    userSnap = snap.docs[0];
  }
  if (!uid) throw new functions.https.HttpsError("invalid-argument", "uid または name を指定してください");
  if (!userSnap) userSnap = await db.collection("users").doc(uid).get();

  const [draftsSnap, notifSnap] = await Promise.all([
    db.collectionGroup("entryDrafts").where("invitedUids", "array-contains", uid).get(),
    db.collection("users").doc(uid).collection("notifications")
      .where("type", "==", "entry_invite").orderBy("createdAt", "desc").limit(20).get(),
  ]);

  const drafts = draftsSnap.docs.map((d) => {
    const dd = d.data() || {};
    const approvals = dd.approvals || {};
    const seenAt = dd.seenAt || {};
    return {
      tournamentId: d.ref.parent.parent.id,
      draftId: d.id,
      teamName: dd.teamName || "",
      leaderName: dd.leaderName || "",
      isLeader: dd.leaderUid === uid,
      myApproval: approvals[uid] || "pending",
      mySeen: !!seenAt[uid],
      approvedCount: Object.values(approvals).filter((v) => v === "approved").length,
      totalInvited: Array.isArray(dd.invitedUids) ? dd.invitedUids.length : 0,
    };
  });

  const notifications = notifSnap.docs.map((d) => {
    const nd = d.data() || {};
    return {
      teamName: nd.teamName || "",
      tournamentName: nd.tournamentName || "",
      read: nd.read === true,
      createdAt: nd.createdAt ? nd.createdAt.toDate().toISOString() : null,
    };
  });

  return {
    uid,
    nickname: userSnap.exists ? (userSnap.data().nickname || null) : null,
    // このユーザーが承認待ちのまま止まっている招待（キャプテン視点でも自分視点でも使える）
    pendingForMe: drafts.filter((x) => x.myApproval === "pending" && !x.isLeader),
    allDrafts: drafts,
    // notifications ドキュメントが実際に作られているか（通知作成自体が失敗していないかの確認）
    entryInviteNotifications: notifications,
  };
});

// 承認待ちの招待通知を再送する。entryDrafts のデータ自体（招待状態）は一切変更せず、
// entry_invite 通知だけを対象ユーザーに作り直す。通知が消された／何らかの理由で
// 届かなかった場合の救済用。呼べるのはそのドラフトのキャプテン・大会の主催者・管理者のみ。
exports.resendEntryInviteNotification = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const uid = context.auth.uid;
  const db = admin.firestore();

  const tournamentId = data && data.tournamentId ? String(data.tournamentId) : "";
  const draftId = data && data.draftId ? String(data.draftId) : "";
  const targetUid = data && data.targetUid ? String(data.targetUid) : "";
  if (!tournamentId || !draftId || !targetUid) {
    throw new functions.https.HttpsError("invalid-argument", "tournamentId・draftId・targetUid を指定してください");
  }

  const tRef = db.collection("tournaments").doc(tournamentId);
  const draftRef = tRef.collection("entryDrafts").doc(draftId);
  const [draftSnap, tSnap] = await Promise.all([draftRef.get(), tRef.get()]);
  if (!draftSnap.exists) throw new functions.https.HttpsError("not-found", "招待が見つかりません");
  const draft = draftSnap.data() || {};
  const organizerId = (tSnap.data() || {}).organizerId;
  const isAdmin = (await db.collection("users").doc(uid).get()).data()?.isAdmin === true;
  if (draft.leaderUid !== uid && organizerId !== uid && !isAdmin) {
    throw new functions.https.HttpsError("permission-denied", "再通知できるのはキャプテン・主催者・管理者のみです");
  }

  const invited = Array.isArray(draft.invitedUids) ? draft.invitedUids : [];
  if (!invited.includes(targetUid)) {
    throw new functions.https.HttpsError("not-found", "対象のユーザーはこの招待の対象に含まれていません（別アカウントを招待している可能性があります）");
  }
  const approvals = draft.approvals || {};
  if (approvals[targetUid] === "approved") {
    throw new functions.https.HttpsError("failed-precondition", "既に承認済みです（再通知の必要はありません）");
  }

  const tName = (tSnap.data() || {}).name || "";
  const leaderUid = draft.leaderUid || "";
  await db.collection("users").doc(targetUid).collection("notifications").add({
    type: "entry_invite",
    tournamentId,
    tournamentName: tName,
    draftId,
    teamName: draft.teamName || "",
    senderId: leaderUid,
    senderName: draft.leaderName || "",
    senderAvatar: (draft.memberAvatars || {})[leaderUid] || "",
    message: `が大会「${tName}」のチーム「${draft.teamName}」への参加承認を待っています`,
    resend: true,
    read: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { resent: true, targetUid, teamName: draft.teamName || "", tournamentName: tName };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// フォロー数の自動更新（Firestoreトリガー）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// followers サブコレクションが作成された → followersCount +1
exports.onFollowerCreated = functions.firestore
  .document("users/{userId}/followers/{followerId}")
  .onCreate(async (snap, context) => {
    const { userId } = context.params;
    try {
      await admin.firestore().collection("users").doc(userId).update({
        followersCount: admin.firestore.FieldValue.increment(1),
      });
    } catch (e) {
      console.error(`[onFollowerCreated] ${userId}: ${e.message}`);
    }
  });

// followers サブコレクションが削除された → followersCount -1
exports.onFollowerDeleted = functions.firestore
  .document("users/{userId}/followers/{followerId}")
  .onDelete(async (snap, context) => {
    const { userId } = context.params;
    try {
      await admin.firestore().collection("users").doc(userId).update({
        followersCount: admin.firestore.FieldValue.increment(-1),
      });
    } catch (e) {
      console.error(`[onFollowerDeleted] ${userId}: ${e.message}`);
    }
  });

// following サブコレクションが作成された → followingCount +1
exports.onFollowingCreated = functions.firestore
  .document("users/{userId}/following/{followId}")
  .onCreate(async (snap, context) => {
    const { userId } = context.params;
    try {
      await admin.firestore().collection("users").doc(userId).update({
        followingCount: admin.firestore.FieldValue.increment(1),
      });
    } catch (e) {
      console.error(`[onFollowingCreated] ${userId}: ${e.message}`);
    }
  });

// following サブコレクションが削除された → followingCount -1
exports.onFollowingDeleted = functions.firestore
  .document("users/{userId}/following/{followId}")
  .onDelete(async (snap, context) => {
    const { userId } = context.params;
    try {
      await admin.firestore().collection("users").doc(userId).update({
        followingCount: admin.firestore.FieldValue.increment(-1),
      });
    } catch (e) {
      console.error(`[onFollowingDeleted] ${userId}: ${e.message}`);
    }
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// FCMプッシュ通知ヘルパー
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * ユーザーの通知設定を確認し、FCMトークンを取得
 * @param {string} userId - 送信先ユーザーID
 * @param {string} settingKey - notificationSettings内のキー (例: 'chat', 'follow')
 * @returns {Promise<string|null>} FCMトークン（通知OFF/トークンなしならnull）
 */
/**
 * ユーザーの通知設定を確認し、有効なFCMトークン一覧を返す
 * @returns {string[]} トークン配列（設定OFFまたはトークンなしの場合は空配列）
 */
async function getFcmTokensIfEnabled(userId, settingKey) {
  const db = admin.firestore();
  const userDoc = await db.collection("users").doc(userId).get();
  if (!userDoc.exists) return [];

  const settings = userDoc.data()?.notificationSettings || {};
  if (settings.push === false) return [];
  if (settingKey && settings[settingKey] === false) return [];

  const privateDoc = await db
    .collection("users").doc(userId)
    .collection("private").doc("info")
    .get();
  const data = privateDoc.data() || {};
  // 複数デバイス対応: fcmTokens配列を優先、なければfcmToken単体
  const tokens = data.fcmTokens || [];
  if (tokens.length > 0) return [...new Set(tokens)]; // 重複除去
  return data.fcmToken ? [data.fcmToken] : [];
}

// 後方互換: 単一トークンを返す旧API
async function getFcmTokenIfEnabled(userId, settingKey) {
  const tokens = await getFcmTokensIfEnabled(userId, settingKey);
  return tokens.length > 0 ? tokens[0] : null;
}

/**
 * 複数トークンにFCM送信 + 無効トークン自動削除
 */
async function calcBadgeCount(db, userId) {
  let total = 0;
  const chats = await db.collection("chats")
    .where("members", "array-contains", userId)
    .get();
  for (const doc of chats.docs) {
    const unreadMap = doc.data().unreadCount || {};
    const cnt = unreadMap[userId];
    if (typeof cnt === "number" && cnt > 0) total += cnt;
  }
  const notifs = await db.collection("users").doc(userId)
    .collection("notifications")
    .where("read", "==", false)
    .count()
    .get();
  total += notifs.data().count || 0;
  return total;
}

async function sendFcmToTokens(tokens, payload) {
  if (tokens.length === 0) return;
  const db = admin.firestore();

  // ユーザーごとに実際の未読数を計算してバッジに反映
  const badgeCache = {};
  const results = await Promise.allSettled(
    tokens.map(async (t) => {
      if (!(t.userId in badgeCache)) {
        badgeCache[t.userId] = await calcBadgeCount(db, t.userId);
      }
      const badgeCount = badgeCache[t.userId];

      const privateRef = db.collection("users").doc(t.userId)
        .collection("private").doc("info");
      await privateRef.set(
        { badgeCount: badgeCount },
        { merge: true }
      );

      const enrichedPayload = {
        ...payload,
        apns: {
          headers: {
            "apns-priority": "10",
            "apns-push-type": "alert",
          },
          payload: {
            aps: {
              alert: {
                title: payload.notification?.title || "",
                body: payload.notification?.body || "",
              },
              badge: badgeCount,
              sound: "default",
              "mutable-content": 1,
            },
          },
          ...(payload.apns || {}),
        },
        android: {
          priority: "high",
          notification: {
            sound: "default",
            channelId: "chat_messages",
            ...(payload.android?.notification || {}),
          },
          ...(payload.android || {}),
        },
      };
      return admin.messaging().send({ ...enrichedPayload, token: t.token });
    })
  );

  for (let i = 0; i < results.length; i++) {
    if (results[i].status === "rejected") {
      const error = results[i].reason;
      if (
        error?.code === "messaging/registration-token-not-registered" ||
        error?.code === "messaging/invalid-registration-token"
      ) {
        const invalidToken = tokens[i].token;
        await db
          .collection("users").doc(tokens[i].userId)
          .collection("private").doc("info")
          .update({
            fcmTokens: admin.firestore.FieldValue.arrayRemove([invalidToken]),
          })
          .catch(() => {});
      }
    }
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// チャットメッセージ送信時のプッシュ通知
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onChatMessageCreated = functions.firestore
  .document("chats/{chatId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    const { chatId } = context.params;
    const message = snap.data();
    const senderId = message.senderId;
    const senderName = message.senderName || "ユーザー";
    const type = message.type || "text";

    let body;
    if (type === "image") {
      body = "📷 画像を送信しました";
    } else if (type === "file") {
      body = `📎 ${message.fileName || "ファイル"}`;
    } else {
      body = (message.text || "").substring(0, 100);
    }
    if (!body) return null;

    const db = admin.firestore();
    const chatDoc = await db.collection("chats").doc(chatId).get();
    if (!chatDoc.exists) return null;
    const chatData = chatDoc.data();
    const members = chatData.members || [];
    const chatType = chatData.type || "dm";
    const chatName = chatData.name || "";

    // unreadCountの更新はクライアント側で送信時にincrementしているため、ここでは行わない

    const tokens = [];
    for (const memberId of members) {
      if (memberId === senderId) continue;
      // ミュートチェック
      const mutedDoc = await db.collection("users").doc(memberId).collection("mutedChats").doc(chatId).get();
      if (mutedDoc.exists) continue;
      const memberTokens = await getFcmTokensIfEnabled(memberId, "chat");
      for (const t of memberTokens) {
        tokens.push({ token: t, userId: memberId });
      }
    }

    const title = chatType === "dm" ? senderName : chatName;
    const notificationBody = chatType === "dm" ? body : `${senderName}: ${body}`;

    await sendFcmToTokens(tokens, {
      notification: { title, body: notificationBody },
      data: { type: "chat", targetId: chatId, chatType, senderId },
    });

    // ━━━ 公式アカウント チャットボット自動返信 ━━━
    // chatData.chatbotEnabled === false の会話は、運営が手動対応するため自動返信しない。
    // 未設定（既存DM）は従来どおり自動返信する。
    const OFFICIAL_UID = "zlBy8aWUlCYjyy0NUU9HidrQu983";
    if (chatType === "dm" && senderId !== OFFICIAL_UID && members.includes(OFFICIAL_UID) &&
        chatData.chatbotEnabled !== false) {
      try {
        await handleOfficialChatbot(db, chatId, senderId, message.text || "", senderName);
      } catch (e) {
        console.error("Chatbot error:", e);
      }
    }

    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// いいね通知のプッシュ通知
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onNotificationCreatedPush = functions.firestore
  .document("users/{userId}/notifications/{notificationId}")
  .onCreate(async (snap, context) => {
    const { userId } = context.params;
    const data = snap.data();
    const notifType = data.type || "";
    const senderId = data.senderId || "";
    const senderName = data.senderName || "";
    const message = data.message || "";

    // 自分自身への通知はスキップ
    if (senderId === userId) return null;

    // 通知タイプ → 設定キーのマッピング
    const settingKeyMap = {
      like: "likeComment",
      comment: "likeComment",
      follow: "follow",
      tournament_announcement: "organizer",
      tournament_end: "tournament",
      waitlist_available: "tournament",
      points_earned: "tournament",
      tournament_created: "tournament",
      deadline_approaching: "reminder",
      slots_low: "tournament",
      official: "official",
      team_join: "team",
      team_leave: "team",
      entry_canceled: "tournament",
      // 大会エントリーの招待（再通知・追加招待も同じ type）と、その結果（成立・辞退）
      entry_invite: "tournament",
      entry_confirmed: "tournament",
      entry_declined: "tournament",
    };

    const settingKey = settingKeyMap[notifType];
    if (!settingKey) return null;

    const userTokens = await getFcmTokensIfEnabled(userId, settingKey);
    if (userTokens.length === 0) return null;

    // 通知タイトルの決定
    let title;
    switch (notifType) {
      case "like":
        title = "いいね";
        break;
      case "comment":
        title = "コメント";
        break;
      case "follow":
        title = "フォロー";
        break;
      case "tournament_announcement":
        title = "大会運営者からのお知らせ";
        break;
      case "tournament_end":
        title = "大会結果";
        break;
      case "waitlist_available":
        title = "空き通知";
        break;
      case "deadline_approaching":
        title = "リマインダー";
        break;
      case "official":
        title = "Sofvo公式";
        break;
      case "team_join":
      case "team_leave":
        title = "チーム";
        break;
      case "entry_invite":
        title = data.resend ? "大会エントリーへの招待（再通知）" : "大会エントリーへの招待";
        break;
      case "entry_confirmed":
        title = "大会エントリー成立";
        break;
      case "entry_declined":
      case "entry_canceled":
        title = "大会エントリー";
        break;
      default:
        title = "Sofvo";
    }

    // 送信者が「システム」の通知は本文に送信者名を付けない（「システムチーム…」のようになるため）
    const body = (senderName && senderName !== "システム") ? `${senderName}${message}` : message;

    // 遷移先データ
    const navData = { type: notifType };
    if (data.tournamentId) navData.tournamentId = data.tournamentId;
    if (data.postId) navData.targetId = data.postId;
    if (notifType === "follow" && senderId) navData.targetId = senderId;

    await sendFcmToTokens(
      userTokens.map((t) => ({ token: t, userId })),
      {
        notification: { title, body: body.substring(0, 100) },
        data: navData,
      }
    );
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 大会リマインダー（毎日9:00 JST実行 — config/reminderSettings で設定可能）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.sendTournamentReminders = functions.pubsub
  .schedule("0 0 * * *") // UTC 0:00 = JST 9:00
  .timeZone("Asia/Tokyo")
  .onRun(async () => {
    const db = admin.firestore();

    // リマインダー設定を読み込み
    const configDoc = await db.collection("config").doc("reminderSettings").get();
    const config = configDoc.exists ? configDoc.data() : null;
    const messageTemplate = (config && config.messageTemplate) ? config.messageTemplate : null;

    // 有効なタイミングを取得（設定がない場合は前日のみ）
    let enabledTimings = [{ key: "1day", label: "前日", enabled: true, daysBefore: 1, hoursBefore: 0 }];
    if (config && Array.isArray(config.timings)) {
      const active = config.timings.filter((t) => t.enabled);
      if (active.length > 0) enabledTimings = active;
    }

    const now = new Date();

    for (const timing of enabledTimings) {
      const daysBefore = timing.daysBefore || 0;

      // 対象日を計算
      const targetDate = new Date(now);
      targetDate.setDate(targetDate.getDate() + daysBefore);

      const yyyy = targetDate.getFullYear();
      const mm = String(targetDate.getMonth() + 1).padStart(2, "0");
      const dd = String(targetDate.getDate()).padStart(2, "0");
      const targetDateStr = `${yyyy}/${mm}/${dd}`;

      // 対象大会を取得
      const tournaments = await db.collection("tournaments")
        .where("date", "==", targetDateStr)
        .where("status", "in", ["募集中", "締切"])
        .get();

      for (const tDoc of tournaments.docs) {
        const tData = tDoc.data();
        const tournamentName = tData.title || "大会";
        const venue = tData.venue || tData.location || "";
        const dateStr = tData.date || "";
        const timeStr = tData.time || "";
        const dateTimeStr = timeStr ? `${dateStr} ${timeStr}` : dateStr;

        // メッセージ生成
        let message;
        if (messageTemplate) {
          message = messageTemplate
            .replace(/\{大会名\}/g, tournamentName)
            .replace(/\{日時\}/g, dateTimeStr)
            .replace(/\{会場\}/g, venue);
        } else {
          if (timing.key === "7days") {
            message = `「${tournamentName}」の開催まであと1週間です！`;
          } else if (timing.key === "3days") {
            message = `「${tournamentName}」の開催まであと3日です！`;
          } else if (timing.key === "morning") {
            message = `本日「${tournamentName}」が開催されます！`;
          } else if (timing.key === "1hour") {
            message = `まもなく「${tournamentName}」が開始されます！`;
          } else {
            message = `明日は「${tournamentName}」の開催日です！`;
          }
        }

        // 参加者を取得
        const entries = await tDoc.ref.collection("entries").get();
        const participantUids = new Set();
        for (const entry of entries.docs) {
          const eData = entry.data();
          if (Array.isArray(eData.memberUids)) {
            eData.memberUids.forEach((uid) => { if (uid) participantUids.add(uid); });
          }
          if (eData.enteredBy) participantUids.add(eData.enteredBy);
        }

        // 各参加者にリマインダー通知
        const batch = db.batch();
        for (const uid of participantUids) {
          const notifRef = db.collection("users").doc(uid).collection("notifications").doc();
          batch.set(notifRef, {
            type: "deadline_approaching",
            senderId: "system",
            senderName: "",
            senderAvatar: "",
            message: message,
            tournamentId: tDoc.id,
            read: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      }
    }
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Sofvo公式通知の送信（管理者用 Callable Function）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.sendOfficialNotification = functions.https.onCall(async (data, context) => {
  // 管理者チェック
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  const db = admin.firestore();
  const callerDoc = await db.collection("users").doc(context.auth.uid).get();
  if (!callerDoc.exists || callerDoc.data()?.isAdmin !== true) {
    throw new functions.https.HttpsError("permission-denied", "管理者権限が必要です");
  }

  const { title, message } = data;
  if (!title || !message) {
    throw new functions.https.HttpsError("invalid-argument", "title と message は必須です");
  }

  // 全ユーザーに通知
  const usersSnap = await db.collection("users").get();
  let count = 0;
  const batchSize = 500;
  let batch = db.batch();

  for (const userDoc of usersSnap.docs) {
    const uid = userDoc.id;
    if (uid === context.auth.uid) continue;
    const notifRef = db.collection("users").doc(uid).collection("notifications").doc();
    batch.set(notifRef, {
      type: "official",
      senderId: "sofvo_official",
      senderName: "Sofvo公式",
      senderAvatar: "",
      message: `【${title}】${message}`,
      read: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    count++;
    if (count % batchSize === 0) {
      await batch.commit();
      batch = db.batch();
    }
  }
  if (count % batchSize !== 0) await batch.commit();

  return { success: true, sentCount: count };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// お知らせ作成時に全ユーザーへFCMプッシュ通知（トピック送信）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.onNoticeCreated = functions.firestore
  .document("notices/{noticeId}")
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    // 予約配信はこの時点ではプッシュを送らない（publishScheduledNotices で送る）
    if (data.status === "scheduled") {
      functions.logger.info(`Notice ${context.params.noticeId} is scheduled, skipping push`);
      return null;
    }

    await sendNoticePush(context.params.noticeId, data);
    return null;
  });

/**
 * お知らせドキュメントをFCMトピック all_users に配信する共通関数
 * @param {string} noticeId
 * @param {FirebaseFirestore.DocumentData} data
 */
async function sendNoticePush(noticeId, data) {
  const title = data.title || "お知らせ";
  const body = (data.body || "").substring(0, 100);

  const payload = {
    type: "notice",
    noticeId,
  };
  if (typeof data.link === "string" && data.link.length > 0) {
    payload.link = data.link;
  }

  // 配信対象の OS を判定（'all' | 'ios' | 'android'）
  let topic = "all_users";
  if (data.platform === "ios") {
    topic = "ios_users";
  } else if (data.platform === "android") {
    topic = "android_users";
  }

  const message = {
    topic,
    notification: { title, body },
    data: payload,
    apns: {
      payload: {
        aps: { sound: "default" },
      },
    },
    android: {
      notification: { sound: "default" },
    },
  };

  try {
    await admin.messaging().send(message);
    functions.logger.info(`Notice push sent to topic ${topic}: ${title}`);
  } catch (err) {
    functions.logger.error("Failed to send notice push:", err);
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 予約配信されたお知らせを定期的に公開する
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.publishScheduledNotices = functions.pubsub
  .schedule("every 1 minutes")
  .onRun(async () => {
    const now = admin.firestore.Timestamp.now();
    const snap = await admin
      .firestore()
      .collection("notices")
      .where("status", "==", "scheduled")
      .get();

    if (snap.empty) return null;

    let publishedCount = 0;
    for (const doc of snap.docs) {
      const data = doc.data();
      const scheduledAt = data.scheduledAt;
      if (!scheduledAt || typeof scheduledAt.toMillis !== "function") continue;
      if (scheduledAt.toMillis() > now.toMillis()) continue;

      try {
        await doc.ref.update({
          status: "published",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          publishedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await sendNoticePush(doc.id, data);
        publishedCount++;
      } catch (err) {
        functions.logger.error(`Failed to publish scheduled notice ${doc.id}:`, err);
      }
    }

    if (publishedCount > 0) {
      functions.logger.info(`Published ${publishedCount} scheduled notice(s)`);
    }
    return null;
  });

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// アクセス解析データ取得（管理者/公式アカウント専用）
// セキュリティルールを回避するため Admin SDK を使用
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.getAnalytics = functions.runWith({ timeoutSeconds: 120, memory: "512MB" }).https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
  // 認証チェック
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "認証が必要です" }); return;
  }
  let uid;
  try {
    const decoded = await admin.auth().verifyIdToken(authHeader.split("Bearer ")[1]);
    uid = decoded.uid;
  } catch (e) {
    res.status(401).json({ error: "無効なトークンです" }); return;
  }

  const db = admin.firestore();
  const userDoc = await db.collection("users").doc(uid).get();
  if (!userDoc.exists) {
    res.status(403).json({ error: "ユーザーが見つかりません" }); return;
  }
  const userData = userDoc.data();
  if (!userData.isAdmin && !userData.isOfficial) {
    res.status(403).json({ error: "管理者または公式アカウントのみ利用可能です" }); return;
  }

  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const weekAgo = new Date(today.getTime() - 7 * 86400000);
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
  const fourteenDaysAgo = new Date(today.getTime() - 13 * 86400000);
  const thirtyDaysAgo = new Date(today.getTime() - 30 * 86400000);

  const usersRef = db.collection("users");
  const monthTimestamp = admin.firestore.Timestamp.fromDate(monthStart);
  const todayTimestamp = admin.firestore.Timestamp.fromDate(today);
  const weekAgoTimestamp = admin.firestore.Timestamp.fromDate(weekAgo);
  const thirtyDaysAgoTimestamp = admin.firestore.Timestamp.fromDate(thirtyDaysAgo);

  // 全クエリを並列実行
  const [
    totalSnap, recentUsersSnap,
    postsSnap, tournamentsSnap, chatsSnap,
    dauSnap, wauSnap, mauSnap,
    totalChatsSnap,
  ] = await Promise.all([
    usersRef.count().get(),
    usersRef.where("createdAt", ">=", admin.firestore.Timestamp.fromDate(fourteenDaysAgo)).get(),
    db.collection("posts").where("createdAt", ">=", monthTimestamp).count().get(),
    db.collection("tournaments").where("createdAt", ">=", monthTimestamp).count().get(),
    db.collection("chats").where("createdAt", ">=", monthTimestamp).count().get(),
    usersRef.where("lastActiveAt", ">=", todayTimestamp).count().get(),
    usersRef.where("lastActiveAt", ">=", weekAgoTimestamp).count().get(),
    usersRef.where("lastActiveAt", ">=", thirtyDaysAgoTimestamp).count().get(),
    db.collection("chats").count().get(),
  ]);

  const totalUsers = totalSnap.data().count || 0;
  const dauCount = dauSnap.data().count || 0;
  const wauCount = wauSnap.data().count || 0;
  const mauCount = mauSnap.data().count || 0;
  const totalChats = totalChatsSnap.data().count || 0;

  // 日別カウント計算
  const dailyCounts = {};
  for (let i = 0; i < 14; i++) {
    const d = new Date(fourteenDaysAgo.getTime() + i * 86400000);
    dailyCounts[`${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`] = 0;
  }
  let todayCount = 0, weekCount = 0, monthCount = 0;
  for (const doc of recentUsersSnap.docs) {
    const createdAt = doc.data().createdAt;
    if (!createdAt) continue;
    const date = createdAt.toDate();
    const dayKey = `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
    if (dailyCounts[dayKey] !== undefined) dailyCounts[dayKey]++;
    const dayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    if (dayStart >= today) todayCount++;
    if (dayStart >= weekAgo) weekCount++;
    if (dayStart >= monthStart) monthCount++;
  }

  if (monthStart < fourteenDaysAgo) {
    const earlySnap = await usersRef
      .where("createdAt", ">=", admin.firestore.Timestamp.fromDate(monthStart))
      .where("createdAt", "<", admin.firestore.Timestamp.fromDate(fourteenDaysAgo))
      .get();
    monthCount += earlySnap.size;
  }

  // リテンション率（簡易版）
  let retentionRate = 0;
  try {
    const prevWeekStartTimestamp = admin.firestore.Timestamp.fromDate(new Date(weekAgo.getTime() - 7 * 86400000));
    const prevSnap = await usersRef.where("lastActiveAt", ">=", prevWeekStartTimestamp).where("lastActiveAt", "<", weekAgoTimestamp).count().get();
    const prevCount = prevSnap.data().count || 0;
    if (prevCount > 0) {
      const retainedSnap = await usersRef.where("lastActiveAt", ">=", weekAgoTimestamp).count().get();
      retentionRate = Math.min(Math.round((retainedSnap.data().count / prevCount) * 100), 100);
    }
  } catch (e) { console.warn("retention calc failed:", e.message); }
  // 今月のチャットメッセージ数（collectionGroup — インデックスが必要）
  let monthMessages = 0;
  try {
    const monthMessagesSnap = await db
      .collectionGroup("messages")
      .where("createdAt", ">=", monthTimestamp)
      .count()
      .get();
    monthMessages = monthMessagesSnap.data().count || 0;
  } catch (e) {
    console.warn("messages collectionGroup query failed:", e.message);
  }

  // ユーザーセグメント（experience フィールド別）
  const allUsersSnap = await usersRef.select("experience").get();
  const segments = {};
  for (const doc of allUsersSnap.docs) {
    const exp = doc.data().experience || "unknown";
    segments[exp] = (segments[exp] || 0) + 1;
  }

  return {
    todayNew: todayCount,
    weekNew: weekCount,
    monthNew: monthCount,
    totalUsers,
    dailyCounts,
    monthPosts: postsSnap.data().count || 0,
    monthTournaments: tournamentsSnap.data().count || 0,
    monthChats: chatsSnap.data().count || 0,
    dau: dauCount,
    wau: wauCount,
    mau: mauCount,
    retentionRate,
    monthMessages,
    totalChats,
    segments,
  };
  res.json(result);

  } catch (e) {
    console.error("getAnalytics error:", e);
    res.status(500).json({ error: e.message || "Unknown error" });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ブロードキャストチャットメッセージ送信
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.broadcastChatMessage = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "ログインが必要です");
  }

  const db = admin.firestore();
  const senderId = context.auth.uid;

  // 権限チェック
  const senderDoc = await db.collection("users").doc(senderId).get();
  if (!senderDoc.exists) {
    throw new functions.https.HttpsError("permission-denied", "ユーザーが見つかりません");
  }
  const senderData = senderDoc.data();
  if (!senderData.isAdmin && !senderData.isOfficial) {
    throw new functions.https.HttpsError("permission-denied", "管理者または公式アカウントのみ利用可能です");
  }

  const { message, target } = data;
  if (!message || typeof message !== "string" || message.trim().length === 0) {
    throw new functions.https.HttpsError("invalid-argument", "メッセージを入力してください");
  }

  const senderName = senderData.nickname || senderData.displayName || "公式";

  // ターゲットユーザーを取得
  const usersRef = db.collection("users");
  let usersSnap;
  const now = new Date();
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 86400000);
  const thirtyDaysAgoTs = admin.firestore.Timestamp.fromDate(thirtyDaysAgo);

  switch (target) {
    case "active":
      usersSnap = await usersRef.where("lastActiveAt", ">=", thirtyDaysAgoTs).get();
      break;
    case "beginner":
      usersSnap = await usersRef.where("experience", "==", "1年未満").get();
      break;
    case "dormant":
      usersSnap = await usersRef.where("lastActiveAt", "<", thirtyDaysAgoTs).get();
      break;
    default:
      usersSnap = await usersRef.get();
  }

  let sentCount = 0;
  const batchSize = 500;
  let batch = db.batch();
  let batchCount = 0;

  for (const userDoc of usersSnap.docs) {
    const targetUserId = userDoc.id;
    if (targetUserId === senderId) continue;

    const targetData = userDoc.data();
    const targetName = targetData.nickname || targetData.displayName || "ユーザー";

    // 既存のDMチャットを検索
    const existingChats = await db.collection("chats")
      .where("type", "==", "dm")
      .where("members", "array-contains", senderId)
      .get();

    let chatId = null;
    for (const chatDoc of existingChats.docs) {
      const members = chatDoc.data().members || [];
      if (members.includes(targetUserId)) {
        chatId = chatDoc.id;
        break;
      }
    }

    // DMチャットが存在しない場合は作成
    if (!chatId) {
      const chatRef = await db.collection("chats").add({
        type: "dm",
        members: [senderId, targetUserId],
        memberNames: { [senderId]: senderName, [targetUserId]: targetName },
        lastMessage: "",
        lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
        lastRead: { [senderId]: admin.firestore.FieldValue.serverTimestamp() },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      chatId = chatRef.id;
    }

    // メッセージを送信
    const messageRef = db.collection("chats").doc(chatId).collection("messages").doc();
    batch.set(messageRef, {
      text: message.trim(),
      senderId: senderId,
      senderName: senderName,
      type: "text",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // チャットのlastMessageを更新
    const chatRef = db.collection("chats").doc(chatId);
    batch.update(chatRef, {
      lastMessage: message.trim().substring(0, 100),
      lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    batchCount += 2;
    sentCount++;

    // バッチサイズ上限でコミット
    if (batchCount >= batchSize) {
      await batch.commit();
      batch = db.batch();
      batchCount = 0;
    }
  }

  if (batchCount > 0) {
    await batch.commit();
  }

  return { sentCount };
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ユーザーセグメント取得（管理者用 Callable Function）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.getUserSegments = functions.runWith({ timeoutSeconds: 120, memory: "512MB" }).https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (!(await assertAdminRequest(req, res))) return;

  try {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "認証が必要です" }); return;
  }
  let uid;
  try {
    const decoded = await admin.auth().verifyIdToken(authHeader.split("Bearer ")[1]);
    uid = decoded.uid;
  } catch (e) {
    res.status(401).json({ error: "無効なトークンです" }); return;
  }

  const db = admin.firestore();
  const userDoc = await db.collection("users").doc(uid).get();
  if (!userDoc.exists) {
    res.status(403).json({ error: "ユーザーが見つかりません" }); return;
  }
  const userData = userDoc.data();
  if (!userData.isAdmin && !userData.isOfficial) {
    res.status(403).json({ error: "管理者または公式アカウントのみ利用可能です" }); return;
  }

  const now = new Date();
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 86400000);
  const sevenDaysAgo = new Date(now.getTime() - 7 * 86400000);
  const thirtyDaysAgoTimestamp = admin.firestore.Timestamp.fromDate(thirtyDaysAgo);
  const sevenDaysAgoTimestamp = admin.firestore.Timestamp.fromDate(sevenDaysAgo);

  // 全ユーザー取得（必要フィールドのみ）
  const usersSnap = await db.collection("users")
    .select("experience", "area", "gender", "lastActiveAt", "createdAt")
    .get();

  let totalUsers = 0;
  let activeUsers = 0;
  let inactiveUsers = 0;
  let newUsers = 0;

  const experienceSegments = {};
  const areaSegments = {};
  const genderSegments = {};

  // 競技歴のマッピング
  const experienceLabels = {
    "lessThan1": "1年未満",
    "1to3": "1-3年",
    "3to5": "3-5年",
    "5plus": "5年以上",
    "beginner": "1年未満",
    "intermediate": "1-3年",
    "advanced": "3-5年",
    "expert": "5年以上",
  };

  // 性別のマッピング
  const genderLabels = {
    "male": "男性",
    "female": "女性",
    "男性": "男性",
    "女性": "女性",
  };

  for (const doc of usersSnap.docs) {
    const d = doc.data();
    totalUsers++;

    // アクティブ/休眠判定
    const lastActiveAt = d.lastActiveAt;
    if (lastActiveAt && lastActiveAt.toDate() >= thirtyDaysAgo) {
      activeUsers++;
    } else {
      inactiveUsers++;
    }

    // 新規判定
    const createdAt = d.createdAt;
    if (createdAt && createdAt.toDate() >= sevenDaysAgo) {
      newUsers++;
    }

    // 競技歴
    const rawExp = d.experience || "";
    const expLabel = experienceLabels[rawExp] || rawExp || "未設定";
    experienceSegments[expLabel] = (experienceSegments[expLabel] || 0) + 1;

    // エリア
    const area = d.area || "未設定";
    areaSegments[area] = (areaSegments[area] || 0) + 1;

    // 性別
    const rawGender = d.gender || "";
    const genderLabel = genderLabels[rawGender] || rawGender || "未設定";
    genderSegments[genderLabel] = (genderSegments[genderLabel] || 0) + 1;
  }

  return {
    totalUsers,
    activeUsers,
    inactiveUsers,
    newUsers,
    experienceSegments,
    areaSegments,
    genderSegments,
  };
  res.json(result);

  } catch (e) {
    console.error("getUserSegments error:", e);
    res.status(500).json({ error: e.message || "Unknown error" });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 管理者用: ユーザーのメール・パスワード変更
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.updateUserAuth = functions.https.onRequest(async (req, res) => {
  try {
    if (!(await assertAdminRequest(req, res))) return;
    const { uid, email, password } = req.body;
    if (!uid) return res.status(400).json({ error: "uid is required" });

    const updateData = {};
    if (email) updateData.email = email;
    if (password) updateData.password = password;

    await admin.auth().updateUser(uid, updateData);

    // Firestoreのemailも同期
    if (email) {
      await admin.firestore().collection("users").doc(uid).update({ email });
    }

    res.json({ success: true, message: "Updated successfully", updated: Object.keys(updateData) });
  } catch (e) {
    console.error("updateUserAuth error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// アプリ設定更新（latestVersion等）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exports.updateAppConfig = functions.https.onRequest(async (req, res) => {
  try {
    if (!(await assertAdminRequest(req, res))) return;
    const { latestVersion, minVersion, updateMessage } = req.body;
    if (!latestVersion && !minVersion) return res.status(400).json({ error: "latestVersion or minVersion is required" });

    const updateData = {};
    if (latestVersion) updateData.latestVersion = latestVersion;
    if (minVersion) updateData.minVersion = minVersion;
    if (updateMessage !== undefined) updateData.updateMessage = updateMessage;

    await admin.firestore().collection("config").doc("app").set(updateData, { merge: true });
    res.json({ success: true, updated: updateData });
  } catch (e) {
    console.error("updateAppConfig error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ストアの最新バージョンを取得して Firestore に反映
// App Store / Google Play に公開済みの最新バージョンを直接取得する
// ことで、pubspec のバージョンとストア公開のタイミングが
// ずれていても誤ったアップデート案内を出さないようにする。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
async function fetchIosStoreVersion(bundleId) {
  const url = `https://itunes.apple.com/lookup?bundleId=${encodeURIComponent(bundleId)}&country=jp`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`iTunes Lookup HTTP ${res.status}`);
  const data = await res.json();
  if (!data.results || data.results.length === 0) {
    throw new Error("App not found on iTunes Lookup");
  }
  const version = data.results[0].version;
  if (!version) throw new Error("version field missing in iTunes Lookup response");
  return version;
}

async function fetchAndroidStoreVersion(packageName) {
  const url = `https://play.google.com/store/apps/details?id=${encodeURIComponent(packageName)}&hl=en&gl=US`;
  const res = await fetch(url, {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    },
  });
  if (!res.ok) throw new Error(`Play Store HTTP ${res.status}`);
  const html = await res.text();
  // Play Store HTML は頻繁に構造が変わるので複数パターンで試行
  const patterns = [
    /\[\[\["(\d+(?:\.\d+){1,3})"\]\]/,
    /"softwareVersion"\s*:\s*"(\d+(?:\.\d+){1,3})"/,
    /Current Version[\s\S]{0,300}?(\d+\.\d+\.\d+)/i,
  ];
  for (const p of patterns) {
    const m = html.match(p);
    if (m) return m[1];
  }
  throw new Error("Could not parse version from Play Store HTML");
}

async function doSyncStoreVersions() {
  const updates = {};
  const errors = {};
  try {
    updates.latestVersionIos = await fetchIosStoreVersion("com.sofvo.app");
    console.log("[syncStoreVersions] iOS:", updates.latestVersionIos);
  } catch (e) {
    errors.ios = e.message;
    console.error("[syncStoreVersions] iOS error:", e.message);
  }
  try {
    updates.latestVersionAndroid = await fetchAndroidStoreVersion("com.sofvo.app");
    console.log("[syncStoreVersions] Android:", updates.latestVersionAndroid);
  } catch (e) {
    errors.android = e.message;
    console.error("[syncStoreVersions] Android error:", e.message);
  }
  // 旧バージョンのアプリ（単一 latestVersion フィールドのみ見る）向けの
  // 後方互換: iOS/Android の最小値を latestVersion に書き込む。
  // 最小値にするのは、ストア間でバージョンがずれている場合に
  // 「ストアにまだない新バージョンを案内してしまう」誤通知を防ぐため。
  if (updates.latestVersionIos && updates.latestVersionAndroid) {
    updates.latestVersion =
      compareSemver(updates.latestVersionIos, updates.latestVersionAndroid) <= 0
        ? updates.latestVersionIos
        : updates.latestVersionAndroid;
  } else if (updates.latestVersionIos) {
    updates.latestVersion = updates.latestVersionIos;
  } else if (updates.latestVersionAndroid) {
    updates.latestVersion = updates.latestVersionAndroid;
  }
  if (Object.keys(updates).length > 0) {
    updates.lastSyncedAt = admin.firestore.FieldValue.serverTimestamp();
    await admin.firestore().collection("config").doc("app").set(updates, { merge: true });
  }
  return { updates, errors };
}

function compareSemver(a, b) {
  const ap = a.split(".").map((n) => parseInt(n, 10) || 0);
  const bp = b.split(".").map((n) => parseInt(n, 10) || 0);
  const len = Math.max(ap.length, bp.length);
  for (let i = 0; i < len; i++) {
    const av = ap[i] || 0;
    const bv = bp[i] || 0;
    if (av !== bv) return av - bv;
  }
  return 0;
}

// 6時間ごとに自動実行
exports.syncStoreVersions = functions.pubsub
  .schedule("every 6 hours")
  .onRun(async () => {
    try {
      const result = await doSyncStoreVersions();
      console.log("[syncStoreVersions] done:", JSON.stringify(result));
    } catch (e) {
      console.error("[syncStoreVersions] fatal:", e);
    }
  });

// 手動実行用（管理者がデプロイ直後などに叩く想定）
// ?iosVersion=1.0.15&androidVersion=1.0.10 のようにクエリパラメータで
// バージョンを直接指定できる（iTunes/Play の CDN キャッシュ遅延を回避）
exports.syncStoreVersionsNow = functions.https.onRequest(async (req, res) => {
  try {
    const iosOverride = req.query.iosVersion || null;
    const androidOverride = req.query.androidVersion || null;

    if (iosOverride || androidOverride) {
      const updates = { lastSyncedAt: admin.firestore.FieldValue.serverTimestamp() };
      if (iosOverride) updates.latestVersionIos = iosOverride;
      if (androidOverride) updates.latestVersionAndroid = androidOverride;
      if (updates.latestVersionIos && updates.latestVersionAndroid) {
        updates.latestVersion =
          compareSemver(updates.latestVersionIos, updates.latestVersionAndroid) <= 0
            ? updates.latestVersionIos
            : updates.latestVersionAndroid;
      } else if (updates.latestVersionIos) {
        updates.latestVersion = updates.latestVersionIos;
      } else if (updates.latestVersionAndroid) {
        updates.latestVersion = updates.latestVersionAndroid;
      }
      await admin.firestore().collection("config").doc("app").set(updates, { merge: true });
      // FieldValue.serverTimestamp() は JSON 化すると {} になるため、レスポンスには ISO 日時を載せる
      const { lastSyncedAt: _ts, ...written } = updates;
      res.json({
        success: true,
        mode: "manual",
        ...written,
        syncedAt: new Date().toISOString(),
      });
      return;
    }

    const result = await doSyncStoreVersions();
    const { lastSyncedAt: _ts, ...written } = result.updates || {};
    res.json({
      success: true,
      mode: "auto",
      ...written,
      errors: result.errors,
      syncedAt: new Date().toISOString(),
    });
  } catch (e) {
    console.error("syncStoreVersionsNow error:", e);
    res.status(500).json({ error: e.message });
  }
});

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 公式アカウント チャットボット（Gemini API）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
const CHATBOT_SYSTEM = `あなたは「Sofvo（ソフボ）」の公式サポートアシスタントです。
Sofvoはソフトバレーボールに特化したマッチングアプリです。
ユーザーからの質問に丁寧かつ具体的に日本語で回答してください。

【Sofvoとは】
ソフトバレーボールの大会運営・チームマッチング・コミュニティアプリ。
Web版（sofvo.com）・iOS（App Store）・Android（Google Play）で利用可能。

【主な機能と使い方】
■ 大会
- 大会作成: マイページ → 大会管理 → 右下の「＋」ボタン → 大会名・日程・会場・コート数・募集チーム数・参加費・カテゴリ・ルールを設定
- エントリー: 「さがす」タブ → 大会を選択 → 「エントリーする」→ チーム名とメンバーを入力
- エントリー取消: 大会詳細ページの自分のエントリーから「エントリー取消」
- 対戦表・スコア入力: 大会詳細 → 主催者メニュー → 対戦表管理（CSVインポートも可能）
- ステータス: 準備中→募集中→エントリー締切→大会準備中→開催中→終了（主催者が変更可能）
- 大会の編集・削除: 大会管理画面から可能

■ メンバー募集
- 作成: 「さがす」タブ → メンバー募集タブ → 右下の「＋」ボタン → 募集内容・日時・場所・レベル・人数を入力
- 応募: 募集詳細 → 「応募する」→ 主催者が承認すると参加確定
- 締切: 募集管理画面から「締切」に変更

■ チャット
- DM: 相手のプロフィール → 「メッセージを送る」
- グループチャット: チャットタブ → 右上の「＋」ボタン → フォロー中のユーザーを追加
- メッセージ削除: 自分のメッセージを長押し → 削除
- チャット削除/退出: チャット一覧で左スワイプ

■ タイムライン・投稿
- 投稿: ホーム画面右下のペンアイコン → テキスト・画像を投稿
- 削除: 自分の投稿の「…」メニュー → 削除
- 報告: 投稿の「…」メニュー → 報告

■ フォロー
- フォロー: 相手のプロフィール → 「フォロー」ボタン
- フォロー/フォロワー確認: マイページのフォロー数・フォロワー数をタップ
- ブロック: 相手のプロフィール → 右上メニュー → 「ブロック」

■ プロフィール
- 編集: マイページ → プロフィール編集 → ニックネーム・アイコン・自己紹介・ポジション・地域を変更

■ 通知
- 種類: チャット新着・大会更新・フォロー・エントリー関連
- 届かない場合: ①端末設定でSofvoの通知を許可 ②アプリ内の設定→通知設定をON ③ログアウト→再ログイン

■ アカウント
- 作成: メール・Google・Appleアカウントで登録可能。メール登録は確認メール認証が必要
- パスワードリセット: ログイン画面「パスワードをお忘れですか？」から
- メールアドレス変更: 設定 → アカウントセクション（Google/Appleログインは変更不可）
- アカウント削除: 設定 → 最下部の「アカウント削除」（全データが削除され、取り消し不可）

■ その他
- Web版とアプリ版の違い: 基本機能は同じ。アプリ版はプッシュ通知対応
- 不具合報告: 設定 →「フィードバック」またはこのチャットで報告
- 利用規約・プライバシーポリシー: 設定画面の最下部にリンクあり

【回答ルール】
- 具体的な操作手順を含めて回答する（例: 「マイページ → 大会管理 → ＋ボタン」のように画面遷移を示す）
- 1回の回答は2-5文程度で簡潔にまとめる
- 分からない場合は推測せず「担当者が確認のうえ、改めてご連絡いたします。少々お待ちください。」と返す
- 文末は「〜です」「〜ください」「〜いただけます」のように、丁寧で落ち着いた敬語で答える
- 過度になれなれしい表現・タメ口・過剰な感嘆符（！の多用）は使わない。丁寧で親切な接客のトーンを保つ
- 絵文字は原則使わない（どうしても必要な場合のみ控えめに1つまで）
- ユーザーの名前が分かる場合は使わない（プライバシー配慮）
- 「テスト」「あ」など意味のないメッセージには「こんにちは。ご不明な点がございましたら、お気軽にお問い合わせください。下の「？」ボタンからカテゴリを選ぶこともできます。」と返す

【バグ・不具合報告の場合】
ユーザーが「バグ」「不具合」「動かない」「エラー」「おかしい」「落ちる」「フリーズ」「表示されない」などの言葉を使った場合、以下のように段階的にヒアリングする：

1. まず一言添えて、具体的な情報を聞く：
「ご不便をおかけして申し訳ございません。状況を詳しく教えていただけますでしょうか。」
「① どの画面で発生しましたか？（例: 大会詳細、チャット、マイページなど）」
「② どのような操作をされた時でしょうか？（例: ボタンを押した、画面を開いたなど）」
「③ スクリーンショットを送っていただけると、より正確に調査できます。」

2. 情報をもらったら：
「ありがとうございます。開発チームに共有し、調査いたします。修正でき次第お知らせします。」

3. スクリーンショットをもらったら：
「画像をありがとうございます。状況を確認しました。開発チームで確認いたします。」

【機能改善・要望の場合】
ユーザーが「こうしてほしい」「こんな機能がほしい」「改善」「要望」「追加してほしい」などの言葉を使った場合：

1. まず具体的な内容を聞く：
「ご提案ありがとうございます。もう少し詳しく教えていただけますでしょうか。」
「① どの機能（画面）に関する要望でしょうか？」
「② 具体的にどのように変わると良いとお考えですか？」

2. 内容をもらったら：
「承知しました。開発チームに共有いたします。貴重なご意見をありがとうございます。」

【Sofvoに関係ない質問の場合】
「申し訳ございません。Sofvoに関するご質問にお答えしています。Sofvoについてお困りのことがございましたら、お気軽にお問い合わせください。」
- 過度になれなれしい表現は避け、丁寧で落ち着いた敬語で話す
- 絵文字は原則使わない（どうしても必要な場合のみ控えめに）
- 回答の最後に関連する操作への案内を付ける（例:「大会の作成は マイページ → 大会管理 → ＋ボタン から行えます。」）
- 読みやすいように適切に改行する（文章が長い時は2-3文ごとに空行を入れる\\n\\n、箇条書きは改行で区切る）
- 手順を説明する時は番号付きリスト（1. 2. 3.）を使って改行する`;

async function handleOfficialChatbot(db, chatId, senderId, userMessage, senderName) {
  if (!userMessage || userMessage.trim().length === 0) return;

  const GEMINI_KEY = process.env.GEMINI_API_KEY;
  if (!GEMINI_KEY) {
    console.error("GEMINI_API_KEY not set");
    return;
  }

  const OFFICIAL_UID = "zlBy8aWUlCYjyy0NUU9HidrQu983";

  // 直近の会話履歴を取得（コンテキスト用、最大40件）
  const recentMessages = await db.collection("chats").doc(chatId)
    .collection("messages")
    .orderBy("createdAt", "desc")
    .limit(40)
    .get();

  // 会話履歴を Gemini の contents 形式に変換。
  // ・画像/ファイルもプレースホルダーとして残す（スクショの文脈を保つ）
  // ・削除済みは除外
  let history = [];
  const msgs = recentMessages.docs.reverse();
  for (const doc of msgs) {
    const d = doc.data();
    if (d.deleted) continue;
    let text = d.text;
    if (!text || text.trim().length === 0) {
      if (d.type === "image") text = "[画像を送信しました]";
      else if (d.type === "file") text = `[ファイルを送信しました: ${d.fileName || ""}]`;
      else continue;
    }
    history.push({
      role: d.senderId === OFFICIAL_UID ? "model" : "user",
      parts: [{ text }],
    });
  }

  // Gemini は先頭ターンが user である必要があるため、先頭の model 発話を落とす
  while (history.length > 0 && history[0].role === "model") history.shift();
  // 同一ロールが連続する場合はまとめて交互ターンにする（文脈の一貫性を上げる）
  const mergedHistory = [];
  for (const turn of history) {
    const last = mergedHistory[mergedHistory.length - 1];
    if (last && last.role === turn.role) {
      last.parts.push(...turn.parts);
    } else {
      mergedHistory.push({ role: turn.role, parts: [...turn.parts] });
    }
  }
  history = mergedHistory;
  // 履歴が空（先頭 model を落とし切った等）の場合は今回の発話だけで応答
  if (history.length === 0) {
    history = [{ role: "user", parts: [{ text: userMessage }] }];
  }

  // Gemini API呼び出し（thinkingBudget:0で高速化）
  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_KEY}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      system_instruction: { parts: [{ text: CHATBOT_SYSTEM }] },
      contents: history,
      generationConfig: {
        maxOutputTokens: 500,
        temperature: 0.5,
        thinkingConfig: { thinkingBudget: 0 },
      },
    }),
  });

  if (!res.ok) {
    console.error("Gemini API error:", res.status, await res.text());
    return;
  }

  const data = await res.json();
  const reply = data.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!reply) return;

  // 公式アカウントとして返信メッセージを送信 & ログ保存を並列実行
  const officialDoc = await db.collection("users").doc(OFFICIAL_UID).get();
  const officialName = officialDoc.exists ? (officialDoc.data().nickname || "【公式】Sofvo") : "【公式】Sofvo";
  const officialAvatar = officialDoc.exists ? (officialDoc.data().avatarUrl || "") : "";

  await Promise.all([
    // メッセージ送信
    db.collection("chats").doc(chatId).collection("messages").add({
      text: reply,
      senderId: OFFICIAL_UID,
      senderName: officialName,
      senderAvatar: officialAvatar,
      type: "text",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }),
    // 未読カウント更新
    db.collection("chats").doc(chatId).update({
      lastMessage: reply,
      lastMessageTime: admin.firestore.FieldValue.serverTimestamp(),
      lastSenderId: OFFICIAL_UID,
      [`unreadCount.${senderId}`]: admin.firestore.FieldValue.increment(1),
    }),
    // チャットボットログ保存（個人履歴 + 全体分析用）
    db.collection("chatbotLogs").add({
      userId: senderId,
      userName: senderName,
      chatId: chatId,
      userMessage: userMessage,
      botReply: reply,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }),
    // ユーザー別の質問履歴も保存
    db.collection("users").doc(senderId).collection("chatbotHistory").add({
      userMessage: userMessage,
      botReply: reply,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }),
  ]);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Google Drive → タイムライン 定期自動投稿（カテゴリ×交互ローテーション）
//   Drive を「親フォルダ → カテゴリ → 投稿」の3階層で構成し、設定したペース
//   (既定: 月水金12時JST) で1件ずつ、公式アカウント名義で posts に自動投稿する。
//   認証は Sheets 連携と同じ getAccessToken()（Functions既定サービスアカウント）を流用。
//   → 親フォルダをそのサービスアカウントに「閲覧者」以上で共有しておくこと。
//
//   投稿の単位:
//     ・カテゴリ内にサブフォルダがある場合（例 通常/・実機/）… 各サブフォルダ = 1投稿
//       （フォルダ内の複数メディアはファイル名昇順でスワイプ表示）
//     ・カテゴリ内にメディアが直置きの場合（例 リール/）… 各ファイル = 1投稿
//   放出順（cadence）:
//     ・"A" スロットは poolA のカテゴリ、"B" スロットは poolB のカテゴリから出す
//     ・既定 cadence = [A,A,A,A,B] → 通常4件 → 実機1件 → 繰り返し
//     ・その回のスロットのプールが空になったら「投稿を止める」（index も進めない）
//   重複防止: 投稿ドキュメントの driveSourceId（サブフォルダ or ファイルのID）で照合。
//     ※ フォルダの移動はしない（ドライブ側の構成をそのまま保つ）。
//   状態: config/driveInstagramSyncState.postIndex（投稿成功ごとに +1、cadence の位置決定に使用）。
//
//   設定は Firestore の config/driveInstagramSync ドキュメントで上書き可:
//     enabled     (bool)     … false で停止（既定: true）
//     folderId    (string)   … 親フォルダID（既定: 下記定数）
//     officialUid (string)   … 投稿者にする公式アカウントのUID（既定: 下記定数）
//     poolA       (string[]) … "A" スロットのカテゴリ名（既定: ["通常"]）
//     poolB       (string[]) … "B" スロットのカテゴリ名（既定: ["実機"]。※動画は投稿しない=画像のみ）
//     cadence     (string[]) … 放出パターン（既定: ["A","A","B"]）
//     idleMinutes (number)   … 直近この分数以内に更新されたメディアはアップロード中とみなし見送る（既定: 10）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
const DRIVE_OFFICIAL_UID = "zlBy8aWUlCYjyy0NUU9HidrQu983"; // isOfficial:true の公式アカウント
// admin.initializeApp() は storageBucket 未指定のため、明示的にバケット名を指定する
// （既定推論だと *.appspot.com になり、実バケット *.firebasestorage.app と不一致になる）
const DRIVE_STORAGE_BUCKET = "sofvo-19d84.firebasestorage.app";
// 親フォルダIDの既定値（Firestore config/driveInstagramSync.folderId があればそちらが優先）
const DRIVE_SYNC_FOLDER_ID_FALLBACK = "1vIVinzikBTY-p6qEfbhqxjcpFqPkiSED";
const DRIVE_FOLDER_MIME = "application/vnd.google-apps.folder";
const isFolderMime = (m) => m === DRIVE_FOLDER_MIME;
const isVideoMime = (m) => /^video\//.test(m || "");
const isImageMime = (m) => /^image\//.test(m || "");
const isMediaMime = (m) => isImageMime(m) || isVideoMime(m);

async function getDriveSyncConfig() {
  const snap = await admin.firestore().collection("config").doc("driveInstagramSync").get();
  const d = snap.exists ? snap.data() : {};
  return {
    enabled: d.enabled !== false,
    folderId: (d.folderId || DRIVE_SYNC_FOLDER_ID_FALLBACK || "").trim(),
    officialUid: d.officialUid || DRIVE_OFFICIAL_UID,
    poolA: Array.isArray(d.poolA) && d.poolA.length ? d.poolA : ["通常"],
    poolB: Array.isArray(d.poolB) && d.poolB.length ? d.poolB : ["実機"],
    cadence: Array.isArray(d.cadence) && d.cadence.length ? d.cadence : ["A", "A", "A", "A", "B"], // 通常4→実機1
    postDays: Array.isArray(d.postDays) && d.postDays.length ? d.postDays : [1, 4], // 投稿する曜日(1=月..7=日) 既定: 月・木
    idleMinutes: typeof d.idleMinutes === "number" ? d.idleMinutes : 10,
  };
}

async function driveFetch(url, options = {}) {
  const token = await getAccessToken();
  const res = await fetch(url, {
    ...options,
    headers: { Authorization: `Bearer ${token}`, ...(options.headers || {}) },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Drive API ${res.status}: ${body}`);
  }
  return res;
}

// 親フォルダ直下の子（フォルダ/ファイル）を名前順で取得。extraQuery で絞り込み可
async function driveListChildren(parentId, extraQuery = "") {
  const q = `'${parentId}' in parents and trashed=false${extraQuery}`;
  const params = new URLSearchParams({
    q,
    fields: "files(id,name,mimeType,modifiedTime,size)",
    orderBy: "name",
    pageSize: "1000",
    supportsAllDrives: "true",
    includeItemsFromAllDrives: "true",
  });
  const res = await driveFetch(`https://www.googleapis.com/drive/v3/files?${params.toString()}`);
  const data = await res.json();
  return data.files || [];
}

async function driveDownload(fileId) {
  const params = new URLSearchParams({ alt: "media", supportsAllDrives: "true" });
  const res = await driveFetch(`https://www.googleapis.com/drive/v3/files/${fileId}?${params.toString()}`);
  return Buffer.from(await res.arrayBuffer());
}

// バッファを Storage に保存し Firebase 形式のダウンロードURLを返す
async function uploadBufferToStorage(buffer, storagePath, contentType) {
  const bucket = admin.storage().bucket(DRIVE_STORAGE_BUCKET);
  const downloadToken = crypto.randomUUID();
  const file = bucket.file(storagePath);
  await file.save(buffer, {
    resumable: false,
    metadata: {
      contentType,
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });
  return `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(storagePath)}?alt=media&token=${downloadToken}`;
}

// カテゴリ内の「投稿単位」の見出し一覧を名前順で返す（メディア本体はまだ取らない）
//   サブフォルダがある → 各サブフォルダが1投稿(kind:folder)
//   直下にメディアがある → 各ファイルが1投稿(kind:file)
async function getCategoryUnitStubs(categoryId) {
  const children = await driveListChildren(categoryId);
  const subfolders = children.filter((f) => isFolderMime(f.mimeType));
  if (subfolders.length > 0) {
    return subfolders.map((f) => ({ id: f.id, name: f.name, kind: "folder" }));
  }
  return children
    .filter((f) => isImageMime(f.mimeType))
    .map((f) => ({ id: f.id, name: f.name, kind: "file", file: f }));
}

// 投稿単位のメディアファイル一覧（ファイル名昇順）を解決する
async function resolveUnitMedia(stub) {
  if (stub.kind === "file") return [stub.file];
  const files = await driveListChildren(stub.id);
  return files.filter((f) => isImageMime(f.mimeType));
}

// 次に投稿すべき単位を選ぶ（投稿はしない）。cadence の現在スロットのプールから、
// 名前順で「未投稿かつアップロード完了済み」の最初の単位を返す。無ければ unit:null。
async function driveSelectNextUnit(cfg, db) {
  const idleCutoff = Date.now() - cfg.idleMinutes * 60 * 1000;
  const stateSnap = await db.collection("config").doc("driveInstagramSyncState").get();
  const postIndex = stateSnap.exists ? stateSnap.data().postIndex || 0 : 0;
  const slot = cfg.cadence[postIndex % cfg.cadence.length];
  const categoryNames = slot === "A" ? cfg.poolA : cfg.poolB;

  const rootCats = (
    await driveListChildren(cfg.folderId, ` and mimeType='${DRIVE_FOLDER_MIME}'`)
  );
  for (const catName of categoryNames) {
    const cat = rootCats.find((c) => c.name === catName);
    if (!cat) continue;
    const stubs = await getCategoryUnitStubs(cat.id);
    for (const stub of stubs) {
      const dup = await db.collection("posts").where("driveSourceId", "==", stub.id).limit(1).get();
      if (!dup.empty) continue;
      const mediaFiles = await resolveUnitMedia(stub);
      if (mediaFiles.length === 0) continue;
      const uploading = mediaFiles.some(
        (f) => f.modifiedTime && new Date(f.modifiedTime).getTime() > idleCutoff,
      );
      if (uploading) continue;
      return { slot, postIndex, category: catName, unit: { id: stub.id, name: stub.name, mediaFiles } };
    }
  }
  return { slot, postIndex, category: null, unit: null };
}

// 投稿単位を Storage へコピーして posts ドキュメントを作成する（postIndex は触らない）
async function drivePublishUnit(cfg, official, db, unit, category) {
  const media = [];
  const images = [];
  const videos = [];
  let idx = 0;
  for (const f of unit.mediaFiles) {
    const buffer = await driveDownload(f.id);
    const isVideo = isVideoMime(f.mimeType);
    const safeName = (f.name || `file${idx}`).replace(/[^\w.\-]/g, "_");
    const storagePath = `post_images/${cfg.officialUid}/${unit.id}_${String(idx).padStart(2, "0")}_${safeName}`;
    const url = await uploadBufferToStorage(buffer, storagePath, f.mimeType);
    media.push({ type: isVideo ? "video" : "image", url });
    if (isVideo) videos.push(url);
    else images.push(url);
    idx++;
  }

  const postRef = await db.collection("posts").add({
    userId: cfg.officialUid,
    userNickname: official.nickname || "Sofvo公式",
    userAvatarUrl: official.avatarUrl || "",
    text: "",
    images, // 画像URLのみ（旧アプリ・他リーダーとの後方互換）
    videos, // 動画URLのみ
    media, // 表示順を保持した [{type, url}]（新アプリはこれを優先描画）
    likesCount: 0,
    commentsCount: 0,
    autoGenerated: false,
    source: "driveInstagram",
    driveCategory: category,
    driveSourceId: unit.id, // サブフォルダ or ファイルのID（重複防止の照合キー）
    sourceName: unit.name,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { postId: postRef.id, mediaCount: media.length };
}

// 指定カテゴリから「未投稿かつアップロード完了済み」の最初の単位を返す（cadence 無視）
async function driveNextUnitInCategory(cfg, db, categoryName) {
  const idleCutoff = Date.now() - cfg.idleMinutes * 60 * 1000;
  const rootCats = await driveListChildren(cfg.folderId, ` and mimeType='${DRIVE_FOLDER_MIME}'`);
  const cat = rootCats.find((c) => c.name === categoryName);
  if (!cat) return null;
  const stubs = await getCategoryUnitStubs(cat.id);
  for (const stub of stubs) {
    const dup = await db.collection("posts").where("driveSourceId", "==", stub.id).limit(1).get();
    if (!dup.empty) continue;
    const mediaFiles = await resolveUnitMedia(stub);
    if (mediaFiles.length === 0) continue;
    const uploading = mediaFiles.some(
      (f) => f.modifiedTime && new Date(f.modifiedTime).getTime() > idleCutoff,
    );
    if (uploading) continue;
    return { id: stub.id, name: stub.name, mediaFiles };
  }
  return null;
}

// 1回分: cadence に従って次の1件を投稿する処理本体
async function processOneDrivePost() {
  const cfg = await getDriveSyncConfig();
  if (!cfg.enabled) return { skipped: "disabled" };
  if (!cfg.folderId) return { skipped: "no folderId configured (config/driveInstagramSync)" };

  const db = admin.firestore();
  const officialDoc = await db.collection("users").doc(cfg.officialUid).get();
  if (!officialDoc.exists) return { error: `official user not found: ${cfg.officialUid}` };
  const official = officialDoc.data();

  const sel = await driveSelectNextUnit(cfg, db);
  if (!sel.unit) {
    // このスロットのプールが空 → 投稿を止める（index も進めない）
    return { skipped: `pool for slot ${sel.slot} is empty → stop`, slot: sel.slot, postIndex: sel.postIndex };
  }

  const pub = await drivePublishUnit(cfg, official, db, sel.unit, sel.category);

  await db.collection("config").doc("driveInstagramSyncState").set(
    {
      postIndex: sel.postIndex + 1,
      lastSlot: sel.slot,
      lastCategory: sel.category,
      lastUnit: sel.unit.name,
      lastPostedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { posted: pub.postId, slot: sel.slot, category: sel.category, unit: sel.unit.name, mediaCount: pub.mediaCount, postIndex: sel.postIndex + 1 };
}

// テスト用: 指定カテゴリから1件だけ強制投稿する（cadence/postIndex には影響しない）
async function forceOneDrivePost(categoryName) {
  const cfg = await getDriveSyncConfig();
  if (!cfg.folderId) return { skipped: "no folderId configured" };
  const db = admin.firestore();
  const officialDoc = await db.collection("users").doc(cfg.officialUid).get();
  if (!officialDoc.exists) return { error: `official user not found: ${cfg.officialUid}` };
  const official = officialDoc.data();

  const unit = await driveNextUnitInCategory(cfg, db, categoryName);
  if (!unit) return { skipped: `no ready unposted unit in category '${categoryName}'` };

  const pub = await drivePublishUnit(cfg, official, db, unit, categoryName);
  return { posted: pub.postId, category: categoryName, unit: unit.name, mediaCount: pub.mediaCount, forced: true };
}

// 一度きりの追加投稿日（JST・YYYY-MM-DD）。この日は 12:00 JST に1回だけ投稿する。
// 過ぎた日付は今後一致しないため自動的に無効（あとで消さなくてよい）。
const DRIVE_ONE_TIME_POST_DATES = ["2026-07-04"];
const DRIVE_ONE_TIME_POST_HOUR = 12; // 一度きり指定日の投稿時刻（JST）
const DRIVE_REGULAR_POST_HOUR = 20; // 通常(postDays)の投稿時刻（JST）

// 定期実行: 毎日12時・20時(JST)に起動。
//   ・指定日(DRIVE_ONE_TIME_POST_DATES)は12時に1回だけ投稿
//   ・通常の投稿曜日(cfg.postDays 既定 月・木)は20時に投稿
exports.publishDriveScheduledPost = functions
  .runWith({ timeoutSeconds: 540, memory: "2GB" })
  .pubsub.schedule("0 12,20 * * *")
  .timeZone("Asia/Tokyo")
  .onRun(async () => {
    try {
      const cfg = await getDriveSyncConfig();
      const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
      const weekday = nowJst.getUTCDay() === 0 ? 7 : nowJst.getUTCDay(); // 1=月..7=日
      const hour = nowJst.getUTCHours(); // JST の時（+9h シフト済み）
      const dateStr = nowJst.toISOString().slice(0, 10); // JST の YYYY-MM-DD
      const oneTime = hour === DRIVE_ONE_TIME_POST_HOUR && DRIVE_ONE_TIME_POST_DATES.includes(dateStr);
      const regular = hour === DRIVE_REGULAR_POST_HOUR && cfg.postDays.includes(weekday);
      if (!oneTime && !regular) {
        functions.logger.info(`publishDriveScheduledPost: skip (JST ${dateStr} ${hour}h weekday ${weekday})`);
        return null;
      }
      const result = await processOneDrivePost();
      functions.logger.info("publishDriveScheduledPost:", JSON.stringify(result));
    } catch (e) {
      functions.logger.error("publishDriveScheduledPost error:", e);
    }
    return null;
  });

// 手動実行/動作確認用。1回叩くと次の1件を即投稿（cadence どおり）。
// ?category=リール のように指定すると、そのカテゴリから1件だけ強制投稿（テスト用・cadenceを乱さない）。
exports.runDrivePostNow = functions
  .runWith({ timeoutSeconds: 540, memory: "2GB" })
  .https.onRequest(async (req, res) => {
    if (!(await assertAdminRequest(req, res))) return;
    try {
      const category = (req.query.category || "").toString().trim();
      const result = category ? await forceOneDrivePost(category) : await processOneDrivePost();
      res.status(200).json({ ok: true, result });
    } catch (e) {
      functions.logger.error("runDrivePostNow error:", e);
      res.status(500).json({ ok: false, error: String(e && e.message ? e.message : e) });
    }
  });

// 確認専用（投稿しない）: サービスアカウントから見たドライブの構造・カテゴリ別の
// 投稿済み/残り件数・cadence の現在位置・次に投稿される単位を返す。
exports.driveSyncStatus = functions
  .runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    try {
      const cfg = await getDriveSyncConfig();
      if (!cfg.folderId) {
        res.status(200).json({ ok: false, reason: "no folderId configured", config: cfg });
        return;
      }

      const db = admin.firestore();
      const rootCats = await driveListChildren(cfg.folderId, ` and mimeType='${DRIVE_FOLDER_MIME}'`);
      const allCategoryNames = [...cfg.poolA, ...cfg.poolB];

      const categories = [];
      for (const catName of allCategoryNames) {
        const pool = cfg.poolA.includes(catName) ? "A" : "B";
        const cat = rootCats.find((c) => c.name === catName);
        if (!cat) {
          categories.push({ name: catName, pool, exists: false });
          continue;
        }
        const stubs = await getCategoryUnitStubs(cat.id);
        let posted = 0;
        const pendingNames = [];
        for (const s of stubs) {
          const dup = await db.collection("posts").where("driveSourceId", "==", s.id).limit(1).get();
          if (dup.empty) pendingNames.push(s.name);
          else posted++;
        }
        categories.push({
          name: catName,
          pool,
          unit: stubs.length ? (stubs[0].kind === "file" ? "ファイル=1投稿" : "フォルダ=1投稿") : "空",
          total: stubs.length,
          posted,
          pending: pendingNames.length,
          pendingNames: pendingNames.slice(0, 60),
        });
      }

      const sel = await driveSelectNextUnit(cfg, db);
      const next = sel.unit
        ? { slot: sel.slot, category: sel.category, unit: sel.unit.name, mediaCount: sel.unit.mediaFiles.length }
        : { slot: sel.slot, category: null, note: "このスロットのプールは空 → 停止" };

      const stateSnap = await db.collection("config").doc("driveInstagramSyncState").get();
      const postIndex = stateSnap.exists ? stateSnap.data().postIndex || 0 : 0;

      res.status(200).json({
        ok: true,
        folderId: cfg.folderId,
        cadence: cfg.cadence,
        poolA: cfg.poolA,
        poolB: cfg.poolB,
        postIndex,
        currentSlot: cfg.cadence[postIndex % cfg.cadence.length],
        next,
        categories,
      });
    } catch (e) {
      functions.logger.error("driveSyncStatus error:", e);
      res.status(500).json({ ok: false, error: String(e && e.message ? e.message : e) });
    }
  });

// Web での動画再生対策＆診断:
//   ① Storage バケットに CORS を設定（Web の video 要素が読めるように）
//   ② 直近の動画投稿のURLヘッダ（content-type / CORS 等）を返して原因切り分け
exports.driveVideoDebug = functions
  .runWith({ timeoutSeconds: 120, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    if (!(await assertAdminRequest(req, res))) return;
    try {
      const db = admin.firestore();

      // ① バケット CORS 設定（Web 再生のため）
      let cors = "set";
      try {
        await admin.storage().bucket(DRIVE_STORAGE_BUCKET).setCorsConfiguration([
          {
            origin: ["*"],
            method: ["GET", "HEAD"],
            responseHeader: ["Content-Type", "Range", "Content-Range", "Accept-Ranges", "Content-Length"],
            maxAgeSeconds: 3600,
          },
        ]);
      } catch (e) {
        cors = "error: " + (e && e.message ? e.message : e);
      }

      // ② 最新の動画付き driveInstagram 投稿を探す
      const snap = await db.collection("posts").where("source", "==", "driveInstagram").limit(50).get();
      let latest = null;
      snap.forEach((d) => {
        const data = d.data();
        const vids = Array.isArray(data.videos) ? data.videos : [];
        if (vids.length > 0) {
          const t = data.createdAt && data.createdAt.toMillis ? data.createdAt.toMillis() : 0;
          if (!latest || t > latest.t) latest = { url: vids[0], t, sourceName: data.sourceName };
        }
      });

      if (!latest) {
        res.status(200).json({ ok: true, cors, note: "no driveInstagram post with videos found" });
        return;
      }

      const head = await fetch(latest.url, { headers: { Range: "bytes=0-1", Origin: "https://sofvo.com" } });
      res.status(200).json({
        ok: true,
        cors,
        video: {
          sourceName: latest.sourceName,
          status: head.status,
          contentType: head.headers.get("content-type"),
          contentLength: head.headers.get("content-length"),
          contentRange: head.headers.get("content-range"),
          acceptRanges: head.headers.get("accept-ranges"),
          accessControlAllowOrigin: head.headers.get("access-control-allow-origin"),
        },
      });
    } catch (e) {
      functions.logger.error("driveVideoDebug error:", e);
      res.status(500).json({ ok: false, error: String(e && e.message ? e.message : e) });
    }
  });

// リセット: これまで自動投稿した driveInstagram 投稿を全削除し、放出位置(postIndex)を0に戻す。
//   → Drive のフォルダは消さないので、次回からまた最初(post001)から出し直せる。
exports.resetDrivePosts = functions
  .runWith({ timeoutSeconds: 300, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    if (!(await assertAdminRequest(req, res))) return;
    try {
      const db = admin.firestore();
      const snap = await db.collection("posts").where("source", "==", "driveInstagram").get();
      const docs = snap.docs;
      let deleted = 0;
      for (let i = 0; i < docs.length; i += 400) {
        const batch = db.batch();
        for (const d of docs.slice(i, i + 400)) batch.delete(d.ref);
        await batch.commit();
        deleted += docs.slice(i, i + 400).length;
      }
      // 放出位置(cadence)をリセット
      await db.collection("config").doc("driveInstagramSyncState").set(
        { postIndex: 0, lastResetAt: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true },
      );
      res.status(200).json({ ok: true, deleted, postIndexReset: 0 });
    } catch (e) {
      functions.logger.error("resetDrivePosts error:", e);
      res.status(500).json({ ok: false, error: String(e && e.message ? e.message : e) });
    }
  });
